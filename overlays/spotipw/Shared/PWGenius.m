#import "PWGenius.h"
#import "Core/SGCore.h"
#import "Core/PWDiagnostics.h"
#import "Core/PWProviderSupport.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import <SafariServices/SafariServices.h>

static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static UIViewController *presenter(UIView *view) {
    UIResponder *responder = view;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    UIViewController *vc = (id)responder ?: view.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
@interface PWGeniusSheet : UIViewController
@property (nonatomic, copy) NSString *line, *trackTitle, *artist;
@property (nonatomic, strong) UITextView *text;
@property (nonatomic, strong) NSURL *pageURL;
@property (nonatomic) BOOL cancelled;
@end
@implementation PWGeniusSheet
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Explication Genius";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Genius ↗" style:UIBarButtonItemStylePlain target:self action:@selector(openPage)];
    self.text = [UITextView new]; self.text.editable = NO; self.text.selectable = YES;
    self.text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.text.adjustsFontForContentSizeCategory = YES;
    self.text.textContainerInset = UIEdgeInsetsMake(22, 18, 22, 18);
    self.text.frame = self.view.bounds; self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.text];
    [self show:@"Recherche de l’annotation…"]; [self loadAnnotation];
}
- (void)close { self.cancelled = YES; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)show:(NSString *)body {
    if (self.cancelled) return;
    self.text.text = [NSString stringWithFormat:@"%@ — %@\n\n« %@ »\n\n%@", self.trackTitle, self.artist, self.line, body];
}
- (void)openPage {
    if (!self.pageURL) return;
    SFSafariViewController *web = [[SFSafariViewController alloc] initWithURL:self.pageURL];
    [self presentViewController:web animated:YES completion:nil];
}
- (void)loadAnnotation {
    NSString *term = [NSString stringWithFormat:@"%@ %@", self.trackTitle, self.artist];
    self.pageURL = PWQueryURL(@"https://genius.com/search", @{@"q":term});
    NSString *token = PWSecret(@"genius");
    NSDictionary *headers = token.length ? @{@"Authorization":[@"Bearer " stringByAppendingString:token]} : @{};
    PWEvent(@"genius", @"search_started", 0);
    __weak PWGeniusSheet *weak = self;
    PWJSON(PWQueryURL(@"https://api.genius.com/search", @{@"q":term}), headers, ^(NSDictionary *root, NSInteger status) {
        PWGeniusSheet *sheet = weak; if (!sheet || sheet.cancelled) return;
        NSArray *hits = [root[@"response"] isKindOfClass:NSDictionary.class] ? root[@"response"][@"hits"] : nil;
        if (![hits isKindOfClass:NSArray.class]) {
            PWEvent(@"genius", @"search_unavailable", status);
            [sheet show:@"Genius n’a pas fourni de réponse exploitable. Tu peux configurer un jeton d’accès Genius dans Mod Settings → Genius, ou consulter la page avec le bouton Genius ↗."]; return;
        }
        NSDictionary *song = nil;
        for (id hit in hits) {
            if (![hit isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *candidate = hit[@"result"];
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            NSString *artist = [candidate[@"primary_artist"] isKindOfClass:NSDictionary.class] ? str(candidate[@"primary_artist"][@"name"]) : @"";
            if (PWMatches(sheet.trackTitle, str(candidate[@"title"])) && PWMatches(sheet.artist, artist)) { song = candidate; break; }
        }
        if (!song || ![song[@"id"] isKindOfClass:NSNumber.class]) {
            PWEvent(@"genius", @"no_exact_song_match", 0);
            [sheet show:@"Aucune correspondance sûre pour ce titre et cet artiste. Ouvre Genius pour choisir la bonne version."]; return;
        }
        NSURL *page = [NSURL URLWithString:str(song[@"url"])];
        if ([page.scheme isEqualToString:@"https"] && [page.host isEqualToString:@"genius.com"]) sheet.pageURL = page;
        [sheet referents:[song[@"id"] stringValue] headers:headers page:1 matches:[NSMutableArray array]];
    });
}
- (void)referents:(NSString *)songID headers:(NSDictionary *)headers page:(NSInteger)page matches:(NSMutableArray *)matches {
    __weak PWGeniusSheet *weak = self;
    PWJSON(PWQueryURL(@"https://api.genius.com/referents", @{@"song_id":songID, @"text_format":@"plain", @"per_page":@"50", @"page":@(page).stringValue}), headers, ^(NSDictionary *root, NSInteger status) {
        PWGeniusSheet *sheet = weak; if (!sheet || sheet.cancelled) return;
        NSArray *refs = [root[@"response"] isKindOfClass:NSDictionary.class] ? root[@"response"][@"referents"] : nil;
        if (![refs isKindOfClass:NSArray.class]) {
            PWEvent(@"genius", @"annotations_unavailable", status);
            [sheet show:@"Les annotations sont indisponibles pour le moment. Consulte la page Genius ou réessaie plus tard."]; return;
        }
        for (id ref in refs) {
            if (![ref isKindOfClass:NSDictionary.class]) continue;
            if (!PWFragmentMatches(sheet.line, str(ref[@"fragment"]))) continue;
            id annotations = ref[@"annotations"]; if (![annotations isKindOfClass:NSArray.class]) continue;
            for (id annotation in annotations) {
                if (![annotation isKindOfClass:NSDictionary.class]) continue;
                id body = annotation[@"body"]; if (![body isKindOfClass:NSDictionary.class]) continue;
                NSString *plain = str(body[@"plain"]);
                if (plain.length && ![matches containsObject:plain]) [matches addObject:plain];
            }
        }
        if (refs.count == 50 && page < 5) { [sheet referents:songID headers:headers page:page + 1 matches:matches]; return; }
        PWEvent(@"genius", @"annotations_matched", matches.count);
        NSString *body = matches.count ? [[matches componentsJoinedByString:@"\n\n———\n\n"] stringByAppendingString:@"\n\nSource : Genius. Les annotations peuvent être des interprétations de la communauté. Le bouton Genius ouvre la source et ses auteurs."] : @"Aucune annotation disponible pour ce passage. La page Genius peut proposer des explications pour d’autres lignes.";
        [sheet show:body];
    });
}
@end
void PWShowGenius(NSString *trackID, NSString *line, UIView *source) {
    if (!SGEnabled(PWKeyGenius) || !line.length) return;
    SPTPlayerTrack *track = SGKaraokeTrackFor(trackID);
    if (!track && (!trackID.length || [trackID isEqualToString:SGKaraokePlayingTrack()])) track = SGPlayerState().track;
    UIViewController *vc = presenter(source); if (!vc || [vc isKindOfClass:PWGeniusSheet.class]) return;
    PWGeniusSheet *sheet = [PWGeniusSheet new]; sheet.line = line;
    sheet.trackTitle = track.trackTitle ?: @""; sheet.artist = track.artistName ?: @"";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sheet];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [vc presentViewController:nav animated:YES completion:nil];
}
// Native text is selected only when it matches one of this track's known lyric
// lines. Never interpret arbitrary buttons or headings as a lyric.
@interface PWNativeGeniusGesture : UILongPressGestureRecognizer
@end
@implementation PWNativeGeniusGesture
- (instancetype)init { if ((self = [super initWithTarget:nil action:nil])) { [self addTarget:self action:@selector(held)]; self.minimumPressDuration = 0.5; self.cancelsTouchesInView = YES; } return self; }
- (void)held {
    if (self.state != UIGestureRecognizerStateBegan) return;
    NSString *track = SGKaraokePlayingTrack();
    CGPoint point = [self locationInView:self.view];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:self.view];
    while (stack.count) {
        UIView *view = stack.lastObject; [stack removeLastObject];
        if (view.hidden || view.alpha < 0.05 || !CGRectContainsPoint([view convertRect:view.bounds toView:self.view], point)) continue;
        if ([view isKindOfClass:UILabel.class]) {
            NSString *text = ((UILabel *)view).text;
            for (SGKaraokeLine *line in SGKaraokeLinesForTrack(track)) {
                if (PWMatches(text, SGKaraokeLineText(line))) { PWShowGenius(track, SGKaraokeLineText(line), self.view); return; }
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
}
@end
void PWInstallNativeGenius(UIView *view) {
    if (!SGEnabled(PWKeyGenius)) return;
    for (UIGestureRecognizer *g in view.gestureRecognizers) if ([g isKindOfClass:PWNativeGeniusGesture.class]) return;
    [view addGestureRecognizer:[PWNativeGeniusGesture new]];
}
