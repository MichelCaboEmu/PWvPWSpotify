# Corrections après les diagnostics de 5923e441fa70

Le journal fourni montre trois échecs identiques de métadonnées Spotify (`items`,
`tracks`, document de playlist : HTTP 404), avant tout appel YouTube. Il ne permet
pas de distinguer une restriction de l’API d’un problème d’identifiant/session.
`annotations_matched: 0` compte les résultats pour une sélection ; ce n’est pas un
code HTTP et cela ne signifie pas que Genius échoue sur toutes les chansons.

## Lecture native des playlists

`PWNativePlaylist.swift` lit uniquement le modèle de la playlist affichée, au clic.
Les champs ont été vérifiés dans les métadonnées Swift du binaire Spotify 9.1.78
(917802214) de l’artefact du run 36600291269 :

- `FTPViewModelImplementation.entityModel` : `PLPlaylistEntityModel`.
- `entityURL`, `metadata` (`ListMetadata`), `tracks` (`PLPlaylistTracksModel`).
- `ListMetadata.isLoaded`, `totalLength`.
- `PLPlaylistTracksModel.items`, `loadedItemCount`, `unfilteredLength`, `unrangedLength`.
- `PlaylistEntityItem.loaded(ListItem)` / `.unloaded(...)`.
- `ListItem.uri`, `isRecommendation`, `metadata` ; métadonnées `name`, `artists`,
  `duration` et `ListItem.Artist.name`.

La réflexion Swift évite les offsets mémoire et les sélecteurs supposés. L’URI et les compteurs du modèle des titres doivent correspondre. Le compteur
d’en-tête est informatif : il peut être nul ou obsolète indépendamment des titres. Une liste partielle, filtrée ou avec
des recommandations injectées n’est jamais mise en file comme liste complète.
L’API Web reste le secours si la lecture native est indisponible/incomplète.
Les grandes playlists chargées par fenêtres peuvent donc encore échouer : cette
correction ne fournit pas un chargeur natif paginé. Les nouveaux événements
`playlist_native_loaded`, `playlist_native_incomplete` et
`playlist_native_unavailable` permettent de distinguer ces cas sans journaliser
les titres, identifiants ou jetons.

## Genius et dossier

La correspondance accepte une annotation couvrant une sous-phrase ou plusieurs
lignes, normalise les apostrophes et conserve des limites de mots. Jusqu’à trois
fiches de titre/artiste identiques sont essayées si aucune annotation ne correspond.
La pagination continue jusqu’à une page vide (20 pages maximum), avec protection
contre les pages répétées. Les annotations déjà trouvées restent affichées si une
page suivante échoue. Aucune garantie de couverture de toutes les annotations.

Le sélecteur de dossier est présenté en plein écran. L’écriture coordonnée d’un
fichier vide temporaire vérifie l’accès avant de mémoriser le dossier ; un retour
`false` de `startAccessingSecurityScopedResource` ne rejette plus à lui seul les
URLs du conteneur de l’app. La sélection, l’annulation et l’échec sont journalisés.

## Vérification sur iPhone encore nécessaire

1. Choisir un dossier local, puis un dossier iCloud et vérifier la confirmation.
2. Télécharger une petite playlist sans filtre : attendre `playlist_native_loaded`
   puis les étapes YouTube. Vérifier séparément une grande playlist et Titres likés.
3. Refaire un appui long qui fonctionnait déjà, puis celui dont l’annotation porte
   sur une partie seulement de la ligne. Comparer avec la page Genius.

Les tests de règles et la compilation iOS ne remplacent pas ces essais sur appareil.

## Retour appareil sur 471c9b3

Le journal rapporte `playlist_native_incomplete` avec zéro comme compteur
`ListMetadata.totalLength`. Le message affiché provenait du test
`totalLength == unfilteredLength == unrangedLength` : cette égalité attribuait
à tort tout écart d’en-tête à un filtre. Le journal précédent ne contenait pas
les autres compteurs, donc il ne prouvait pas qu’un filtre était réellement actif.

Le lecteur préfère maintenant `FTPViewModelImplementation.playlistModel`
→ `FTPModelImplementation.model` lorsque disponible, puis utilise les compteurs
du seul `PLPlaylistTracksModel` pour établir sa complétude. Le chemin de champs
supplémentaire a été vérifié dans les mêmes métadonnées Swift de 9.1.78.
Le compteur d’en-tête ne bloque plus une liste cohérente ; une liste partielle
ou filtrée reste refusée. Les cinq compteurs, la source du snapshot et la raison
de refus sont désormais journalisés sans contenu de playlist.

Dans la file, les cellules ont une hauteur automatique. Toucher l’erreur
principale déplie tout son texte ; un appui long copie l’erreur entière, également
pour les erreurs des morceaux et des files en pause. Les tests de règles couvrent
l’en-tête nul/obsolète, la préférence du modèle courant et le maintien du refus
des listes réellement partielles. Validation sur iPhone encore nécessaire.

## Retour appareil sur ab206f8 : HTTP 302 de YouTube Music

Les quatre compteurs de titres valent 72 : la playlist est complète et le
problème précédent est résolu pour cette liste. Le nouvel échec survient à
`youtube_music_config_http: 302`. Une requête publique sans cookies a reproduit
la redirection de `music.youtube.com/` vers `consent.youtube.com/m`.

Une redirection publique entre les hôtes YouTube autorisés est maintenant
suivie. Une redirection vers le consentement déclenche un état distinct et une
ligne « Choisir les cookies YouTube ». La page officielle s’ouvre dans une
WKWebView temporaire isolée ; l’utilisateur accepte ou refuse lui-même.
Au retour sur YouTube, seuls les cookies de préférence SOCS/CONSENT valides
pour youtube.com sont conservés. Ils sont réutilisés pour la configuration,
la recherche et les requêtes de l’extracteur local ; les cookies de compte et
les identifiants de visite ne sont pas transférés. Aucun jeton Spotify ne rejoint
ces sessions. La validation reprend seulement les files mises en pause par cette
étape ; une pause demandée entretemps par l’utilisateur reste respectée.

À vérifier sur iPhone : choisir/refuser les cookies, attendre la reprise, puis
confirmer `audio_saved` et l’existence du M4A. Les refus d’accès, de connexion
ou les vérifications anti-bot restent des erreurs du fournisseur. La correction
de la redirection n’est pas une preuve d’extraction audio réussie sur l’appareil.

## Retour appareil sur c4e9a55 : page sans choix de cookies

La fenêtre ouvrait une nouvelle page d’accueil et utilisait l’identifiant de
navigateur mobile par défaut, tandis que la configuration était demandée avec
`Mozilla/5.0`. La redirection de consentement reçue avec le 302 était perdue.
Ces différences sont une explication possible du parcours divergent observé ;
un réglage du téléphone n’a pas été établi comme cause.

La fenêtre ouvre maintenant la destination exacte reçue du fournisseur, conserve
sa destination de retour et utilise le même identifiant de navigateur que les
requêtes de configuration/recherche. Elle reste temporaire et isolée de Safari.
La ligne devient « Vérifier l’accès YouTube », avec des instructions visibles.
Si la page publique apparaît sans choix de cookies, aucune préférence n’est
fabriquée : la configuration est vérifiée avec la session du téléchargement.
La présence d’un cookie ne suffit plus à reprendre la file. Une page de connexion
ou une réponse sans configuration valide ne confirme pas l’accès. Si le 302
persiste, une vérification manuelle rouvre sa nouvelle destination exacte, sans
boucle automatique.

Nouveaux événements, sans URL ni valeur de cookie :
`youtube_consent_preferences_saved`, `youtube_consent_preferences_absent`,
`youtube_access_verified`, `youtube_access_still_requires_consent`,
`youtube_access_config_missing`, `youtube_access_verification_failed` et
`youtube_access_resumed`. Même après validation de la configuration, l’extraction
audio complète doit être confirmée sur iPhone avec `audio_saved`.

Les sondes publiques suivantes ont reproduit la différence : identité mobile →
HTTP 200 ; identité de la requête de configuration → HTTP 302 vers le consentement.
L’ouverture de cette destination sans l’état du 302 renvoyait HTTP 303 vers
l’accueil. En conservant seulement SOCS/CONSENT fournis par ce 302, la destination
retournait HTTP 200 avec quatre formulaires HTML. Le correctif installe donc cet
état de consentement dans la fenêtre temporaire avant de charger la destination.
Cela ne constitue pas un choix de l’utilisateur. Les valeurs en attente ne sont
pas enregistrées comme préférences confirmées ; aucun cookie de compte/visite
n’est copié. `youtube_consent_state_loaded` contient uniquement le nombre de
cookies temporaires, jamais leurs valeurs. Les tests couvrent cet état en attente
et le refus des cookies de compte, de visite et des réponses d’autres services.
