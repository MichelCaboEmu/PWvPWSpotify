# PWvPWSpotify

Fusion de **spoti.pw v0.21.1 (GPL-3.0)** et **EeveeSpotify Reincarnated**, pour
**Spotify 9.1.78, build 917802214**. Cible utilisateur : iOS 26.4.1.

Le nom affiché sur l’iPhone est **Spotify**. Le dépôt et le fichier IPA conservent
le nom PWvPWSpotify pour identifier la fusion.

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
- La version précédente a été essayée sur iPhone : les vidéos fonctionnent, avec
  un défaut intermittent. Les nouvelles fonctions ci-dessous nécessitent encore
  un essai sur appareil. Consulter les Actions pour leur état de compilation.
  Un nouvel IPA n’existe qu’après succès de **Build PWvPWSpotify IPA**.
- Un banc Objective-C sur macOS contrôle les vrais parseurs : correspondances
  Genius, pages Apple sans vidéo, choix HLS, refus des formats non pris en charge,
  domaines autorisés et échappement des recherches.

## Téléchargement de playlists — expérimental

**Mod Settings → Téléchargement des playlists** propose **YouTube Music** ou
**YouTube**, traités localement par YouTubeKit (Swift / JavaScriptCore). Aucun
serveur, Python ou FFmpeg n’est nécessaire. Une troisième option conserve le
téléchargement officiel Spotify. SpotDL et librespot ne sont pas embarqués.

La flèche de la playlist ouvre la file : liste complète récupérée auprès de
Spotify, recherche du même titre/artiste/durée, puis téléchargement du M4A. Le
bouton reste accessible sur les playlists d’autrui et le redesign conserve aussi
Ajouter. Si Spotify omet la flèche, elle est ajoutée dans la rangée du header.

Choisir le dossier avec Fichiers, ou conserver **Spotify Downloads** dans les
documents de Spotify. Les fichiers existants sont préservés. La file indique les
erreurs et permet de reprendre ; après fermeture de l’app, elle reste en pause
jusqu’à une reprise manuelle. Retirer une playlist de la file laisse ses fichiers
en place. Source et dossier s’appliquent aux prochaines playlists ajoutées.

Ces fichiers sont lisibles dans Fichiers ou une autre application, **pas dans le
cache hors ligne du lecteur Spotify**. Garde l’app ouverte pendant le traitement.
L’accès aux playlists et aux flux dépend des fournisseurs ; un refus ou une
correspondance douteuse produit une erreur visible. Compilation et tests de
parseurs ne remplacent pas une validation sur l’iPhone cible. Détails et limites :
[`docs/playlist-download-feasibility.md`](docs/playlist-download-feasibility.md).

## Vidéos sur l’écran verrouillé (iOS 26)

Dans **Mod Settings → Vidéos de l’écran verrouillé**, choisir la priorité :

- **Spotify, puis les autres sources** (défaut) : conserver les métadonnées vidéo
  natives lorsqu’elles existent ; sinon essayer Apple Music puis la pochette.
- **Apple Music en priorité** : chercher une pochette animée pour le même album
  et le même artiste, puis générer une animation si nécessaire.
- **Animation de la pochette** : produire localement une boucle de six secondes
  avec un léger mouvement et zoom, sans fournisseur vidéo.
- **Spotify uniquement** : garder les vidéos fournies par Spotify.

Les deux fournisseurs complémentaires ont chacun un interrupteur. Aucun import
ni accès aux vidéos personnelles n’est ajouté. Redémarrer après un changement
pour renouveler les objets d’animation déjà conservés par iOS.

**Apple Music est expérimental** : recherche publique iTunes, correspondance
exacte après normalisation, puis vidéo publique de la page d’album. Ce n’est pas
une API officielle de motion artwork. Les changements du site, la disponibilité
régionale ou un album sans vidéo peuvent empêcher la recherche. Seuls les flux
AVC non chiffrés contenant un fichier MP4 unique sont pris en charge. Aucun
identifiant Spotify ni accès au compte Apple Music n’est transmis ; le titre
et l’artiste de l’album servent à la recherche. Le fichier est adapté au format
3:4 demandé par iOS et conservé temporairement dans le cache de l’application.

Le chargement commence quand iOS demande la vidéo. Les requêtes ont des délais
et limites de taille ; les appels simultanés pour la même piste sont regroupés.
Une réponse tardive ne remplace pas les métadonnées d’une nouvelle piste. Le
rafraîchissement des paroles conserve désormais l’identité de la pochette et
évite de renvoyer un ancien état si Spotify vient d’en fournir un nouveau.

**Relancer l’animation** renouvelle l’animation du morceau actuel sans quitter
Spotify. En priorité Spotify, il essaie les sources complémentaires même si
Spotify a annoncé une vidéo qui ne s’affiche pas. Le mod ne peut pas détecter
fiablement l’échec interne du téléchargement vidéo natif ; ce bouton permet de
réessayer. En mode Spotify uniquement, aucune source complémentaire n’est utilisée.

La ligne **Source / état** indique le fournisseur et la préparation du fichier,
pas la preuve de son affichage par iOS. Garder Canvas activé, verrouiller l’iPhone
et toucher la pochette. Les contraintes [Apple](https://developer.apple.com/documentation/mediaplayer/providing-animated-artwork-for-media-items)
restent applicables : économie d’énergie/de données, réduction des animations,
lecture automatique désactivée et température peuvent maintenir l’image fixe.
Le réglage historique **Player → Lock screen widget → Lock screen videos** contrôle
le même interrupteur principal.

## Explications Genius

**Appui long sur une ligne de paroles** : ouvre une fiche avec le passage et ses
annotations. L’appui simple conserve le déplacement dans la chanson. Fonctionne
avec les paroles redessinées ; dans l’interface native, nécessite le plein écran
et un libellé identifiable correspondant à une ligne du moteur de paroles.

La recherche vérifie le titre et l’artiste, puis rapproche la ligne d’un fragment
annoté (mots complets, jamais une correspondance arbitraire). Les annotations sont
attribuées à Genius et peuvent être des interprétations de la communauté. Tous les
passages ne sont pas annotés. Le bouton **Genius ↗** ouvre la source et ses auteurs
avec Safari intégré, sans quitter l’application.

Dans **Mod Settings → Genius — explications → Configurer l’accès Genius**, saisir
si nécessaire le jeton de son application créée sur [Genius](https://genius.com/api-clients).
Il est conservé dans le trousseau de cet appareil, exclu des sauvegardes de réglages
et des journaux. Aucun jeton partagé n’est embarqué. Sans accès à l’API, un message
explique le problème et le bouton Genius reste disponible. La réponse API en direct
n’a pas pu être validée depuis l’environnement de développement ; tester avec un
jeton personnel et un passage annoté reste nécessaire.

## Journaux et crashs

**Mod Settings → Diagnostics et journaux → Exporter les logs** partage un fichier
texte à joindre au message de diagnostic. **Marquer un problème maintenant** ajoute
un repère temporel. **Effacer les journaux** supprime les événements enregistrés.
Rien n’est envoyé automatiquement.

Le fichier contient le commit de compilation, les versions, les transitions de
l’application, les étapes des fournisseurs et leurs codes d’erreur. Les événements
ne recopient ni jetons, ni URL de requêtes, ni titres, ni paroles. Rotation des
journaux à 256 Kio, avec une seule archive. Les exceptions Objective-C non gérées
conservent leurs adresses de pile sans leur message ; MetricKit ajoute les rapports
de crash qu’iOS livre à l’application, avec des données techniques de l’appareil.
Ce mécanisme ne capture pas tous les crashs, arrêts forcés ou arrêts mémoire.

Après un crash, rouvrir l’application puis exporter les logs. Si nécessaire,
joindre aussi le fichier Spotify `.ips` depuis **Réglages iOS → Confidentialité
et sécurité → Analyse et améliorations → Données d’analyse**. Les rapports MetricKit
peuvent arriver plus tard. L’export technique peut être examiné avant son partage.

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
