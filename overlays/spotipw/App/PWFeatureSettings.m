#import "PWFeatureSettings.h"
#import "Core/SGCore.h"
#import "Core/PWDiagnostics.h"
#import "Shared/Player/PWArtworkEngine.h"
#import "Shared/Player/PWLockScreenArtwork.h"
#import "Shared/Genius/PWGenius.h"
#import "Shared/Downloads/PWDownloads.h"

static UIViewController *top(void) {
    UIViewController *result=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(scene.activationState!=UISceneActivationStateForegroundActive||![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows)if(window.isKeyWindow)result=window.rootViewController;
    }
    while(result.presentedViewController)result=result.presentedViewController;
    return result;
}
static void notice(NSString *title,NSString *message){
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[top() presentViewController:alert animated:YES completion:nil];
}
static void exportLogs(void){
    PWEvent(@"diagnostics",@"export_requested",0);
    NSString *report=PWDiagnosticSnapshot();
    NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:@"PWExport"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file=[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"Spotify-diagnostic.txt"]];
    NSError *error=nil;
    if(![report writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error]){notice(@"Export impossible",@"Le fichier de diagnostic n’a pas pu être créé.");return;}
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    UIViewController *vc=top();share.popoverPresentationController.sourceView=vc.view;share.popoverPresentationController.sourceRect=CGRectMake(vc.view.bounds.size.width/2,vc.view.bounds.size.height/2,1,1);
    [vc presentViewController:share animated:YES completion:nil];
}
static void configureGenius(void){
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Accès Genius" message:@"Jeton d’accès de ton application Genius. Il reste dans le trousseau de cet appareil. Laisse le champ vide pour effacer le jeton enregistré." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"Jeton Genius";field.secureTextEntry=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Enregistrer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *token=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!PWSetSecret(@"genius",token))notice(@"Enregistrement impossible",@"Le trousseau a refusé l’enregistrement. Vérifie la signature de l’application.");
    }]];[top() presentViewController:alert animated:YES completion:nil];
}
SGModRow *PWDiagnosticsRow(void){
    return SGWithSymbol(SGPageRow(@"Diagnostics et journaux",^UIViewController *{
        return [[SGModPage alloc] initWithTitle:@"Diagnostics" intro:@"Après un problème, exporte ce fichier et joins-le à ton message. Rien n’est envoyé automatiquement." sections:@[
            SGSection(nil,@[SGActionRow(@"Exporter les logs",@"Partager un fichier texte",^{exportLogs();}),
                SGActionRow(@"Marquer un problème maintenant",@"Ajoute un repère à retrouver dans le journal",^{PWEvent(@"user",@"problem_marker",0);notice(@"Repère ajouté",@"Tu peux maintenant exporter les logs.");}),
                SGActionRow(@"Effacer les journaux",nil,^{PWClearDiagnostics();notice(@"Journaux effacés",@"Les prochains événements seront enregistrés.");})]),
            SGSection(@"Animation",@[SGStatRow(@"Source / état",^NSString *{return PWArtworkEngineStatus();}),
                SGActionRow(@"Relancer l’animation",@"Essaie Apple Music puis la pochette pour le morceau actuel",^{PWRetryArtwork();})])
        ] footer:@"Les journaux contiennent la version, l’état de lecture technique et les erreurs des fournisseurs, sans jetons ni contenu des paroles. Les rapports de crash reçus d’iOS peuvent inclure des informations techniques sur l’appareil et les piles d’appels. Certains crashs et arrêts mémoire nécessitent le rapport .ips de Réglages iOS → Confidentialité et sécurité → Analyse et améliorations → Données d’analyse. Les rapports iOS peuvent arriver au lancement suivant."];
    }),@"doc.text.magnifyingglass");
}
SGModRow *PWDownloadsSettingsRow(void){
    return SGWithSymbol(SGPageRow(@"Téléchargement des playlists",^UIViewController *{
        return [[SGModPage alloc] initWithTitle:@"Téléchargements" intro:@"La flèche d’une playlist ouvre la file de fichiers audio. Les nouvelles playlists utilisent la source et le dossier choisis ici." sections:@[
            SGSection(nil,@[SGChoiceRow(@"Source",nil,PWKeyDownloadSource,@[@"YouTube Music — sur cet iPhone",@"YouTube — sur cet iPhone",@"Téléchargement officiel Spotify"],0),
                SGActionRow(@"Choisir le dossier",@"Sélectionner un dossier dans Fichiers",^{[PWDownloadsBridge chooseFolderFrom:top()];}),
                SGStatRow(@"Dossier",^NSString *{return [PWDownloadsBridge folderName];}),
                SGActionRow(@"Dossier par défaut",@"Spotify Downloads dans les fichiers de Spotify",^{[PWDownloadsBridge resetFolder];}),
                SGActionRow(@"Voir les téléchargements",nil,^{[PWDownloadsBridge presentFrom:top() playlistURI:nil title:nil authorization:nil];}),
                SGStatRow(@"État",^NSString *{return [PWDownloadsBridge summary];})])
        ] footer:@"Les deux sources YouTube utilisent YouTubeKit localement, sans serveur intermédiaire ni abonnement Spotify requis. La disponibilité dépend des fournisseurs et de l’accès à la playlist. Les fichiers M4A sont lisibles dans Fichiers ou une autre app ; ils ne deviennent pas des morceaux hors ligne du lecteur Spotify. Le mode officiel conserve les conditions de Spotify. Garde l’app ouverte pendant le téléchargement. Après fermeture ou suspension, reprends la file ici. Redémarre Spotify après un changement de mode pour actualiser tous les boutons."];
    }),@"arrow.down.circle");
}
SGModRow *PWGeniusSettingsRow(void){
    return SGWithSymbol(SGPageRow(@"Genius — explications",^UIViewController *{
        return [[SGModPage alloc] initWithTitle:@"Genius" intro:@"Appui long sur une ligne pour lire son explication. Un appui simple conserve le déplacement dans la chanson." sections:@[
            SGSection(nil,@[SGSwitchRow(@"Annotations par appui long",nil,PWKeyGenius),
                SGActionRow(@"Configurer l’accès Genius",@"Jeton personnel enregistré dans le trousseau",^{configureGenius();}),
                SGStatRow(@"Jeton",^NSString *{return PWSecret(@"genius").length?@"Enregistré":@"Non configuré";}),
                SGLinkRow(@"Créer un accès Genius",nil,@"https://genius.com/api-clients")])
        ] footer:@"Si l’API exige un jeton ou ne répond pas, le bouton Genius ouvre sa page dans l’application. Les annotations n’existent pas pour tous les passages ; elles peuvent être des interprétations de la communauté. L’appui long est disponible dans les paroles redessinées et, lorsque le texte est identifiable, dans les paroles natives en plein écran."];
    }),@"text.bubble");
}
SGModRow *PWArtworkSettingsRow(void){
    return SGWithSymbol(SGPageRow(@"Vidéos de l’écran verrouillé",^UIViewController *{
        SGModRow *mode=SGChoiceRow(@"Priorité",nil,PWKeyArtworkMode,@[@"Spotify, puis les autres sources",@"Apple Music en priorité",@"Animation de la pochette",@"Spotify uniquement"],0);
        return [[SGModPage alloc] initWithTitle:@"Vidéos de l’écran verrouillé" intro:@"iOS 26 requis. Redémarre Spotify après avoir changé les options." sections:@[
            SGSection(nil,@[SGSwitchRow(@"Vidéos activées",nil,PWKeyLockScreenArtwork),mode,
                SGSwitchRow(@"Apple Music expérimental",@"Recherche l’album à partir de son titre et de l’artiste",PWKeyAppleArtwork),
                SGSwitchRow(@"Animer la pochette en secours",@"Animation calculée sur cet appareil",PWKeyGeneratedArtwork)]),
            SGSection(nil,@[SGStatRow(@"Source / état",^NSString *{return PWArtworkEngineStatus();}),
                SGActionRow(@"Relancer l’animation",@"Réessaie pour le morceau actuel sans fermer Spotify",^{PWRetryArtwork();})])
        ] footer:@"Apple Music utilise les vidéos proposées sur ses pages publiques. Leur disponibilité et leur format peuvent changer. Aucun accès à ton compte Spotify n’est transmis à Apple. Les vidéos sont chargées à la demande, lorsque iOS affiche la pochette. Le mode économie d’énergie et les réglages d’accessibilité d’iOS restent prioritaires."];
    }),@"play.rectangle");
}
