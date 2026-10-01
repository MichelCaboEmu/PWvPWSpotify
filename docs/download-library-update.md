# Bibliothèque, métadonnées et contrôles hors ligne

- Un index dans le dossier de destination rattache chaque URI de playlist à un
  nom lisible. Les relances utilisent ce dossier. Deux playlists différentes
  homonymes sont distinguées par un suffixe numérique. Les pistes déjà présentes
  sont copiées localement entre playlists, sans nouveau transfert réseau.
- La migration copie les anciens fichiers catalogués, persiste les nouveaux
  emplacements, puis retire les anciens fichiers référencés devenus inutiles.
  Elle ne supprime aucun fichier extérieur au catalogue ni dossier non vide.
- L'album et la pochette Spotify sont conservés avec les informations natives.
  L'action de métadonnées peut résoudre l'identifiant exact via Spotify, puis
  consulter Apple iTunes (plusieurs marchés), MusicBrainz et Cover Art Archive.
  Une compilation ne remplace pas un album connu. Sans album connu, les résultats
  contradictoires conservent la pochette existante. Le catalogue mémorise la source.
- Les fichiers restent en M4A, les balises sont écrites sans réencoder l'audio.
  La mise à jour traite aussi les copies présentes dans plusieurs playlists.
- Une erreur média 403 YouTube déclenche exactement une nouvelle extraction et
  un essai après trois secondes. Le secours n'est envisagé qu'après cet échec.
  Une absence de correspondance peut directement déclencher le secours.
- Audius remplace SoundCloud dans les réglages et la source 3. Aucun jeton ou
  abonnement n'est demandé. Seuls les titres dont le téléchargement gratuit est
  autorisé et sans condition d'accès sont utilisés. Son catalogue indépendant
  ne garantit pas une correspondance avec tous les titres de Spotify.
- Les menus contextuels des lignes de playlist et du lecteur plein écran ont une
  commande de téléchargement individuel. Elle conserve les commandes existantes.
- Le lecteur hors ligne plein écran utilise AVPlayer et les fichiers du catalogue,
  pas le cache privé de Spotify. Pochette intégrée, progression, volume, commandes
  système, aléatoire, répétition et file modifiable fonctionnent sans réseau.
  Les actions paroles/artiste/album/radio restent grisées.
- La recherche de playlist conserve son contrôle et sa visibilité gérés par
  Spotify ; le redesign ne masque plus son ancêtre et habille le contrôle.

## Sources techniques

- https://developer.spotify.com/documentation/web-api/reference/get-track
- https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html
- https://musicbrainz.org/doc/MusicBrainz_API/Search
- https://musicbrainz.org/doc/Cover_Art_Archive/API
- https://github.com/AudiusProject/apps/blob/main/packages/docs/docs/public/openapi.yaml
- https://github.com/AudiusProject/apps/blob/main/packages/sdk/src/sdk/api/tracks/TracksApi.ts

## Vérifications sur iPhone

1. Télécharger Avion, vider la file, relancer avec un nouveau titre : même dossier,
   aucune reprise réseau des fichiers présents. Vérifier aussi une deuxième
   playlist du même nom et des noms comportant des séparateurs.
2. Exécuter les métadonnées sur un ancien téléchargement puis une copie dans
   deux playlists : pochette du bon album, lecture inchangée et pas de doublon.
3. Vérifier les deux menus ⋯, avec interfaces classique et redessinée, puis
   annuler un menu et ouvrir immédiatement celui d'un autre titre.
4. Ouvrir une playlist : recherche masquée au repos, disponible au geste de
   défilement vers le haut, recherche et tri encore utilisables.
5. En mode avion, lire, avancer, chercher dans un morceau, répéter, mélanger,
   réordonner la file et réduire le lecteur ; vérifier les commandes verrouillées.
6. Sur 403, les diagnostics doivent présenter tentative 1, délai 3 s, tentative 2,
   puis éventuellement Audius. Pause/vidage pendant le délai annule la reprise.

Les tests CI couvrent les règles de dossiers, correspondances d'album, reprise
bornée/annulation, transport audio, balises et compilation iOS. Ils ne remplacent
pas les vérifications des vues privées Spotify sur un appareil.
