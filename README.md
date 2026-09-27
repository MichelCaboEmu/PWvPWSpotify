# PWvPWSpotify

Fusion de **spoti.pw v0.21.1 (GPL-3.0)** et **EeveeSpotify Reincarnated**, pour
**Spotify 9.1.78, build 917802214**. Cible utilisateur : iOS 26.4.1.

Les deux sources sont fixées par SHA dans `upstreams.json` et référencées comme
sous-modules. `scripts/prepare.py` assemble les sources et applique le profil de
fusion, sans modifier les dépôts d’origine. Les versions récentes de spoti.pw sous
PolyForm Strict ne sont pas utilisées.

## État de validation

- IPA fourni : version/build vérifiés, exécutable arm64 déchiffré (`cryptid = 0`),
  aucun dylib préinjecté détecté. Empreinte dans `input-validation.json`.
- Classes/méthodes du lecteur, de la barre de progression et de Smart Shuffle
  retrouvées dans ce binaire. Ce contrôle ne remplace pas un essai sur appareil.
- Tests locaux : validation Mach-O, activation des hooks complémentaires,
  absence des moteurs Eevee en double et règles de séparation des couches.
- Le workflow **Verify and compile fusion** compile les deux modules après un push.
  Il utilise une table de flags vide uniquement pour contrôler la compilation,
  ne produit aucun IPA et n’est pas une validation fonctionnelle.
- **Aucun essai sur iPhone n’a été réalisé.** Consulter les Actions pour l’état réel
  de compilation. Un IPA n’existe qu’après succès de **Build PWvPWSpotify IPA**.

## Choix des fonctionnalités communes

| Fonction | Implémentation retenue et raison |
|---|---|
| Liquid Glass, écran de lecture, couleurs, gestes, interface épurée | spoti.pw : interface cohérente, documentée sur 9.1.78 |
| Paroles, karaoké, traductions, écran verrouillé | spoti.pw : un moteur commun à l’interface et à la Live Activity |
| SpicyLyrics, Musixmatch, LRCLIB | Adaptateurs spoti.pw ; aucun second intercepteur de paroles |
| Genius, PetitLyrics | Dépôts de paroles Eevee d’origine, exposés comme fournisseurs du moteur spoti.pw |
| Publicités, état du compte, fondu/automix | Port Eevee déjà présent dans spoti.pw 0.21.1 ; les groupes équivalents Eevee ne démarrent pas |
| SponsorBlock | Eevee, avec contrôle d’existence séparé pour l’observateur et la barre de progression |
| Mélange de playlist | Eevee TrueShuffle : exclut les recommandations Smart Shuffle ; ce n’est pas un nouvel algorithme aléatoire |
| Liens partagés, LiveContainer, destination Instagram | Eevee |
| Icônes alternatives, correction CarPlay | Eevee ; les autorisations de signature CarPlay restent nécessaires |
| Protection de session | Option Eevee avancée désactivée par défaut, car elle annule certaines requêtes |
| Effets audio, vibrations, Live Activity, confidentialité, flags | spoti.pw |
| Menu | Une entrée Mod Settings ; les fonctions complémentaires ouvrent Compléments Eevee |

Les choix privilégient l’intégration documentée sur le binaire cible ; ils ne
constituent pas une comparaison de performances mesurée sur appareil. Le second
karaoké Eevee, ses réglages de couleurs en double, ses entrées de réglages et ses
intercepteurs publicités/compte/paroles ne sont pas activés. Les sondes de diagnostic
Eevee et la notification humoristique de l’amont ne sont pas démarrées.

Genius fournit du texte non synchronisé. PetitLyrics conserve la granularité
exposée par son adaptateur Eevee (début des lignes). Les fournisseurs supplémentaires
se choisissent dans **Player → Lyrics → Sources**. Ils ne remplacent pas d’office les
sources choisies par l’utilisateur. Les compléments utilisent le préfixe des
préférences spoti.pw pour participer à sa sauvegarde/réinitialisation.

Les fonctions côté serveur (téléchargement natif de musique, qualité réservée au
compte, AI DJ, etc.) ne sont pas débloquées par cette fusion.

## Construire l’IPA sur GitHub Actions

1. Ouvrir **Actions → Build PWvPWSpotify IPA → Run workflow**.
2. Coller le lien HTTPS direct de l’IPA Spotify **9.1.78 / 917802214 déchiffré et vierge**.
3. Garder l’empreinte proposée pour le fichier fourni dans cette conversation.
   Un autre fichier du même build nécessite sa propre empreinte (ou laisser vide).
4. Attendre le succès du workflow, puis récupérer l’artefact **PWvPWSpotify-9.1.78**.
5. Signer `PWvPWSpotify-9.1.78.ipa` avec son outil de signature.

Le lien IPA n’est pas stocké dans le dépôt et est masqué dans les logs du workflow.
Le résultat est un artefact Actions, pas une release publique ni un téléversement
vers un service tiers. Attention : les artefacts d’un dépôt public restent
accessibles aux utilisateurs GitHub selon les règles GitHub ; ils expirent après
7 jours. Ne fournir aucune clé privée ou mot de passe de certificat dans le dépôt.

L’IPA conserve `com.spotify.client` et peut donc remplacer Spotify installé avec
le même identifiant. Le signer avec l’App ID de son certificat comme l’explique
spoti.pw ; conserver ses extensions pour la Live Activity et le widget.
Liquid Glass nécessite iOS 26+, la Live Activity iOS 17+.

## Construire sur Mac

```sh
git clone --recurse-submodules https://github.com/MichelCaboEmu/PWvPWSpotify.git
cd PWvPWSpotify
# Xcode avec SDK iPhoneOS 26+ et Theos sont nécessaires.
brew install make dpkg ldid
python3 -m pip install 'git+https://github.com/asdfzxcvbn/pyzule-rw.git@740d3716dcd98c20c000f12cdb88f1f0b2a533a4'
git clone https://github.com/BillyCurtis/OpenSpotifySafariExtension.git safari
git -C safari checkout 6523fcd3a45796beb89ce82f3f9ba032c85ae837
export THEOS=/chemin/vers/theos
bash scripts/build.sh /chemin/vers/Spotify-9.1.78.ipa
```

Sorties : IPA, rapports de contrôle et archive des sources correspondantes dans
`out/`. Le workflow utilise Theos `dd5c14bb9d91311e221d51b5bfb8c9e5948156db`.
L’IPA réel régénère sa table de flags depuis son propre exécutable.

## Vérification sur appareil

Après signature : démarrage à froid, connexion, lecture/pause/piste suivante,
recherche/bibliothèque, paroles de plusieurs fournisseurs, Live Activity, widget,
retour depuis l’écran verrouillé, SponsorBlock sur un épisode connu, partage,
changement d’icône, puis redémarrage avec les options activées. Désactiver une
option défaillante et conserver le numéro de build et les logs sans jeton de compte.

## Sources et licences

- [spoti.pw v0.21.1](https://github.com/skopevoj/spoti.pw/tree/v0.21.1), Vojtěch Škopek.
- [EeveeSpotify Reincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated),
  whoeevee et ses contributeurs/mainteneurs.
- [Theos](https://github.com/theos/theos), [cyan](https://github.com/asdfzxcvbn/pyzule-rw),
  [SwiftProtobuf](https://github.com/apple/swift-protobuf),
  [OpenSpotifySafariExtension](https://github.com/BillyCurtis/OpenSpotifySafariExtension).

Les fichiers de fusion sont sous GPL-3.0. Les licences, auteurs et avis des
composants amont restent dans leurs sources, y compris ceux de `vendor/`.
L’archive générée contient les sources modifiées correspondant aux deux modules,
avec la recette de construction, et exclut le binaire Spotify et ses flags extraits.
Ce projet n’est pas affilié à Spotify.
