#import "PWGenius.h"
#import "Core/SGCore.h"
#import "Core/PWDiagnostics.h"
#import "Core/PWProviderSupport.h"
#import "Settings/SGPageStyle.h"
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
@interface PWGeniusSheet : UIViewController <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) NSString *line, *trackTitle, *artist;
@property (nonatomic, strong) UITextView *text;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSURL *pageURL;
@property (nonatomic) BOOL cancelled;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *songs;
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *seenReferents;
@end
@implementation PWGeniusSheet
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Genius";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = SGPageBackground(); self.view.tintColor=SGGreen();
    UINavigationBarAppearance *bar=[UINavigationBarAppearance new];
    [bar configureWithTransparentBackground];
    bar.titleTextAttributes=@{NSForegroundColorAttributeName:UIColor.whiteColor};
    self.navigationController.navigationBar.standardAppearance=bar;
    self.navigationController.navigationBar.scrollEdgeAppearance=bar;
    self.navigationController.navigationBar.tintColor=SGGreen();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.right.square"] style:UIBarButtonItemStylePlain target:self action:@selector(openPage)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel=@"Ouvrir la source sur Genius";
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.alwaysBounceVertical=YES;[self.view addSubview:scroll];
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=20;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-22],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-44]
    ]];
    UILabel *title=[UILabel new];title.text=self.trackTitle;title.numberOfLines=0;
    title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];title.adjustsFontForContentSizeCategory=YES;title.textColor=UIColor.whiteColor;
    [stack addArrangedSubview:title];
    UILabel *artist=[UILabel new];artist.text=self.artist;artist.textColor=SGGrey();artist.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];artist.adjustsFontForContentSizeCategory=YES;artist.numberOfLines=0;
    [stack addArrangedSubview:artist];[stack setCustomSpacing:6 afterView:title];
    UIVisualEffectView *quote=[[UIVisualEffectView alloc] initWithEffect:SGGlassEffect()];
    quote.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;SGShapeGlass(quote,24,NO);
    UILabel *line=[UILabel new];line.translatesAutoresizingMaskIntoConstraints=NO;line.numberOfLines=0;
    line.text=[NSString stringWithFormat:@"« %@ »",self.line];line.textColor=UIColor.whiteColor;
    line.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle3] scaledFontForFont:[UIFont systemFontOfSize:21 weight:UIFontWeightSemibold]];line.adjustsFontForContentSizeCategory=YES;
    [quote.contentView addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:quote.contentView.topAnchor constant:20],
        [line.bottomAnchor constraintEqualToAnchor:quote.contentView.bottomAnchor constant:-20],
        [line.leadingAnchor constraintEqualToAnchor:quote.contentView.leadingAnchor constant:20],
        [line.trailingAnchor constraintEqualToAnchor:quote.contentView.trailingAnchor constant:-20]
    ]];
    [stack addArrangedSubview:quote];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color=SGGreen();self.spinner.hidesWhenStopped=YES;[stack addArrangedSubview:self.spinner];[self.spinner startAnimating];
    self.text=[UITextView new];self.text.editable=NO;self.text.selectable=YES;self.text.scrollEnabled=NO;
    self.text.backgroundColor=UIColor.clearColor;self.text.textColor=UIColor.whiteColor;
    self.text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.text.adjustsFontForContentSizeCategory=YES;
    self.text.textContainerInset=UIEdgeInsetsZero;self.text.textContainer.lineFragmentPadding=0;
    self.text.linkTextAttributes=@{NSForegroundColorAttributeName:SGGreen()};
    self.text.accessibilityLabel=@"Explication Genius";[stack addArrangedSubview:self.text];
    self.text.text=@"Recherche de l’annotation…";[self loadAnnotation];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];self.navigationController.presentationController.delegate=self;
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller { self.cancelled=YES; }
- (void)close { self.cancelled = YES; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)show:(NSString *)body {
    if (self.cancelled) return;
    [self.spinner stopAnimating];
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineSpacing=5;paragraph.paragraphSpacing=12;
    self.text.attributedText=[[NSAttributedString alloc] initWithString:body attributes:@{
        NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleBody],
        NSForegroundColorAttributeName:UIColor.whiteColor, NSParagraphStyleAttributeName:paragraph}];
}
- (void)openPage {
    if (!self.pageURL) return;
    SFSafariViewController *web = [[SFSafariViewController alloc] initWithURL:self.pageURL];
    web.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    web.preferredBarTintColor=SGPageBackground();web.preferredControlTintColor=SGGreen();
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
        sheet.songs = [NSMutableArray array];
        sheet.headers = headers;
        NSMutableSet *seenSongs = [NSMutableSet set];
        for (id hit in hits) {
            if (![hit isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *candidate = hit[@"result"];
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            NSString *artist = [candidate[@"primary_artist"] isKindOfClass:NSDictionary.class] ? str(candidate[@"primary_artist"][@"name"]) : @"";
            if (PWMatches(sheet.trackTitle, str(candidate[@"title"])) && PWMatches(sheet.artist, artist) &&
                [candidate[@"id"] isKindOfClass:NSNumber.class] && ![seenSongs containsObject:candidate[@"id"]]) {
                [sheet.songs addObject:candidate]; [seenSongs addObject:candidate[@"id"]];
                if (sheet.songs.count == 3) break;
            }
        }
        if (!sheet.songs.count) {
            PWEvent(@"genius", @"no_exact_song_match", 0);
            [sheet show:@"Aucune correspondance sûre pour ce titre et cet artiste. Ouvre Genius pour choisir la bonne version."]; return;
        }
        PWEvent(@"genius", @"exact_song_candidates", sheet.songs.count);
        [sheet nextSong];
    });
}
- (void)nextSong {
    if (self.cancelled || !self.songs.count) return;
    NSDictionary *song = self.songs.firstObject; [self.songs removeObjectAtIndex:0];
    NSURL *page = [NSURL URLWithString:str(song[@"url"])];
    if ([page.scheme isEqualToString:@"https"] && [page.host isEqualToString:@"genius.com"]) self.pageURL = page;
    self.seenReferents = [NSMutableSet set];
    [self referents:[song[@"id"] stringValue] headers:self.headers page:1 matches:[NSMutableArray array]];
}
- (void)referents:(NSString *)songID headers:(NSDictionary *)headers page:(NSInteger)page matches:(NSMutableArray *)matches {
    __weak PWGeniusSheet *weak = self;
    PWJSON(PWQueryURL(@"https://api.genius.com/referents", @{@"song_id":songID, @"text_format":@"plain", @"per_page":@"50", @"page":@(page).stringValue}), headers, ^(NSDictionary *root, NSInteger status) {
        PWGeniusSheet *sheet = weak; if (!sheet || sheet.cancelled) return;
        NSArray *refs = [root[@"response"] isKindOfClass:NSDictionary.class] ? root[@"response"][@"referents"] : nil;
        if (![refs isKindOfClass:NSArray.class]) {
            PWEvent(@"genius", @"annotations_unavailable", status);
            if (matches.count) {
                [sheet show:[[matches componentsJoinedByString:@"\n\n———\n\n"] stringByAppendingString:@"\n\nSource : Genius. Certaines pages n’ont pas pu être chargées ; le bouton Genius ouvre la source et ses auteurs."]];
            } else [sheet show:@"Les annotations sont indisponibles pour le moment. Consulte la page Genius ou réessaie plus tard."];
            return;
        }
        PWEvent(@"genius", @"referents_received", refs.count);
        NSUInteger newReferents = 0, fragments = 0;
        for (id ref in refs) {
            if (![ref isKindOfClass:NSDictionary.class]) continue;
            NSNumber *identifier = ref[@"id"];
            if (![identifier isKindOfClass:NSNumber.class] || [sheet.seenReferents containsObject:identifier]) continue;
            [sheet.seenReferents addObject:identifier]; newReferents++;
            if (!PWFragmentMatches(sheet.line, str(ref[@"fragment"]))) continue;
            fragments++;
            id annotations = ref[@"annotations"]; if (![annotations isKindOfClass:NSArray.class]) continue;
            for (id annotation in annotations) {
                if (![annotation isKindOfClass:NSDictionary.class]) continue;
                id body = annotation[@"body"]; if (![body isKindOfClass:NSDictionary.class]) continue;
                NSString *plain = str(body[@"plain"]);
                if (plain.length && ![matches containsObject:plain]) [matches addObject:plain];
            }
        }
        PWEvent(@"genius", @"fragments_matched", fragments);
        // Continue to an empty page even when the service caps per_page below 50.
        // IDs stop a provider which ignores page from looping forever.
        if (newReferents && page < 20) { [sheet referents:songID headers:headers page:page + 1 matches:matches]; return; }
        BOOL incomplete = refs.count && (!newReferents || page == 20);
        if (incomplete) PWEvent(@"genius", @"referents_incomplete", page);
        if (!matches.count && sheet.songs.count) {
            PWEvent(@"genius", @"trying_another_exact_song", 0); [sheet nextSong]; return;
        }
        PWEvent(@"genius", @"annotations_matched", matches.count);
        NSString *body = matches.count ? [[matches componentsJoinedByString:@"\n\n———\n\n"] stringByAppendingString:@"\n\nSource : Genius. Les annotations peuvent être des interprétations de la communauté. Le bouton Genius ouvre la source et ses auteurs."] : @"Aucune annotation n’a pu être associée à cette ligne. Le découpage des paroles ou la version du morceau peut différer sur Genius ; ouvre la source pour vérifier ce passage.";
        if (incomplete && !matches.count) body = @"La lecture des annotations est incomplète. Ouvre la page Genius pour consulter ce passage.";
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
    nav.view.backgroundColor=SGPageBackground();nav.view.tintColor=SGGreen();
    nav.modalPresentationStyle=UIModalPresentationPageSheet;
    nav.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.largeDetent];
    nav.sheetPresentationController.prefersGrabberVisible=YES;
    nav.sheetPresentationController.preferredCornerRadius=28;
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
