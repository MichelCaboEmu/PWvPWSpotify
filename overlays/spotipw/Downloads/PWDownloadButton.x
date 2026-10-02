#import "PWDownloads.h"
#import "Core/SGCore.h"
#import "Core/PWDiagnostics.h"
#import "Shared/Lyrics/Lyrics.h"
#import <objc/message.h>
#import "Shared/Player/PlayerState.h"

static char kContext, kFallback;
@interface PWDownloadModelReference : NSObject
@property (nonatomic, weak) id model;
@end
@implementation PWDownloadModelReference
@end
BOOL PWDownloadsEnabled(void) { return [NSUserDefaults.standardUserDefaults integerForKey:PWKeyDownloadSource] != 2; }

// Selectors and object return encodings verified in the supplied 9.1.78 executable.
static id objectGetter(id object, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return nil;
    NSMethodSignature *signature=[object methodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments!=2 || signature.methodReturnType[0]!='@') return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,sel);
}
static id modelFor(UIView *view) {
    for(UIResponder *r=view;r;r=r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        if (![NSStringFromClass(r.class) containsString:@"FreeTierPlaylist"]) continue;
        id model=objectGetter(objectGetter(r,@"headerController"),@"defaultHeaderViewModel");
        if(model)return model;
    }
    return nil;
}
static NSDictionary *contextFor(id model) {
    id url=objectGetter(model,@"playlistURL");
    NSString *uri=[url isKindOfClass:NSURL.class]?[url absoluteString]:([url isKindOfClass:NSString.class]?url:nil);
    id title=objectGetter(model,@"playlistName");
    if(!uri.length)return nil;
    PWDownloadModelReference *reference = [PWDownloadModelReference new]; reference.model = model;
    return @{@"uri":uri,@"title":[title isKindOfClass:NSString.class]?title:@"Playlist",@"model":reference};
}
static void bindControl(UIView *view, NSDictionary *context) {
    if([view isKindOfClass:UIControl.class]) objc_setAssociatedObject(view,&kContext,context,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for(UIView *child in view.subviews)bindControl(child,context);
}
@interface PWDownloadFallbackTarget : NSObject
+ (instancetype)shared;
- (void)open:(UIControl *)sender;
@end
static void show(UIView *button,NSDictionary *context) {
    UIViewController *vc=nil;
    for(UIResponder *r=button;r;r=r.nextResponder)if([r isKindOfClass:UIViewController.class]){vc=(id)r;break;}
    if(!vc)for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(scene.activationState!=UISceneActivationStateForegroundActive||![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows)if(window.isKeyWindow)vc=window.rootViewController;
    }
    while(vc.parentViewController)vc=vc.parentViewController;
    while(vc.presentedViewController)vc=vc.presentedViewController;
    // Several native targets may receive the same UIControl event. Present once.
    if([vc isKindOfClass:UINavigationController.class]&&[NSStringFromClass(((UINavigationController *)vc).topViewController.class) containsString:@"PWDownloadQueueController"])return;
    if(!vc||vc.isBeingPresented)return;
    PWEvent(@"download",@"button_pressed",0);
    [PWDownloadsBridge presentFrom:vc playlistURI:context[@"uri"] title:context[@"title"] authorization:SGKaraokeSpotifyAuthorization() nativeModel:((PWDownloadModelReference *)context[@"model"]).model];
}
@implementation PWDownloadFallbackTarget
+ (instancetype)shared { static id target;static dispatch_once_t once;dispatch_once(&once,^{target=[self new];});return target; }
- (void)open:(UIControl *)sender { show(sender,objc_getAssociatedObject(sender,&kContext)); }
@end

UIView *PWDownloadControl(UIView *root,id model) {
    if(!PWDownloadsEnabled())return nil;
    NSDictionary *context=contextFor(model);
    __block UIView *found=nil;
    SGForEachView(root,^(UIView *view){if(!found&&[view.accessibilityIdentifier hasPrefix:@"DownloadButton.Granular."])found=view;});
    // Keep Spotify's control whenever it exists. Some free-tier headers omit it entirely.
    if(!found){
        found=objc_getAssociatedObject(root,&kFallback);
        if(!found){
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            button.frame=CGRectMake(0,0,44,44);
            [button setImage:[UIImage systemImageNamed:@"arrow.down.circle"] forState:UIControlStateNormal];
            button.tintColor=UIColor.whiteColor;button.accessibilityLabel=@"Télécharger la playlist";
            button.accessibilityIdentifier=@"PW.DownloadPlaylist";
            [button addTarget:PWDownloadFallbackTarget.shared action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(root,&kFallback,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);found=button;
        }
    }
    bindControl(found,context);
    found.accessibilityHint=@"Ouvre la file de téléchargement de fichiers audio";
    return found;
}
void PWPrepareNativeDownloads(UIView *row) {
    if(!PWDownloadsEnabled())return;
    id model=modelFor(row);if(!model)return;
    UIView *button=PWDownloadControl(row,model);
    if(!button.superview&&[row isKindOfClass:UIStackView.class]){
        [(UIStackView *)row addArrangedSubview:button];
        [button.widthAnchor constraintEqualToConstant:44].active=YES;
        [button.heightAnchor constraintEqualToConstant:44].active=YES;
    }
    // Do not use setHidden: on Spotify's Encore/Overflow stacks.
    for(UIView *v=button;v&&v!=row;v=v.superview){v.alpha=1;v.userInteractionEnabled=YES;}
}

// Classes and row identifiers are documented in PlaylistRows.x, based on
// trees/clean/playlist/02.txt. Use that same evidence under both appearances.
void PWRefreshMetadataSession(void) { [PWDownloadsBridge setSpotifyAuthorization:SGKaraokeSpotifyAuthorization()]; }
static NSDictionary *PWPlayingTrackInfo(void) {
    SPTPlayerState *state=SGPlayerState(); SPTPlayerTrack *track=state.track;
    id link=track.URI;
    NSString *uri=[link isKindOfClass:NSURL.class]?[(NSURL *)link absoluteString]:([link isKindOfClass:NSString.class]?link:nil);
    if(![uri hasPrefix:@"spotify:track:"] || !track.trackTitle.length || !track.artistName.length)return nil;
    NSDictionary *metadata=track.metadata;
    NSString *art=metadata[@"image_xlarge_url"] ?: metadata[@"image_large_url"] ?: metadata[@"image_url"];
    NSMutableDictionary *info=[@{@"id":[uri componentsSeparatedByString:@":"].lastObject,
        @"title":track.trackTitle,@"artist":track.artistName,@"duration":@(state.duration)} mutableCopy];
    if([metadata[@"album_title"] isKindOfClass:NSString.class])info[@"album"]=metadata[@"album_title"];
    if([art isKindOfClass:NSString.class])info[@"artwork"]=art;
    PWRefreshMetadataSession(); return info;
}
static char kPlayingMenu;
static char kTrackInfo, kTrackWatcher, kTrackBadge;
@interface PWTrackMenuWatcher : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIView *button;
@end
@implementation PWTrackMenuWatcher
- (void)tapped { [PWDownloadsBridge selectMenuTrack:objc_getAssociatedObject(self.button,&kPlayingMenu) ? PWPlayingTrackInfo() : objc_getAssociatedObject(self.button, &kTrackInfo)]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return YES; }
@end
static UIView *PWIdentified(UIView *root, NSString *name) {
    __block UIView *result=nil;
    SGForEachView(root, ^(UIView *view){if(!result && [view.accessibilityIdentifier hasPrefix:name]) result=view;});
    return result;
}
static NSString *PWRowText(UIView *root) {
    NSMutableArray *texts=[NSMutableArray array];
    SGForEachView(root, ^(UIView *view){if([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) [texts addObject:((UILabel *)view).text];});
    return [texts componentsJoinedByString:@" "];
}
static void PWApplyTrackRow(UIView *cell) {
    UIImageView *badge=objc_getAssociatedObject(cell,&kTrackBadge);
    badge.alpha=0;
    UIView *button=PWIdentified(cell,@"Components.UI.ContextMenuButton");
    if(button) objc_setAssociatedObject(button,&kTrackInfo,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(!PWDownloadsEnabled())return;
    id model=modelFor(cell); NSDictionary *context=contextFor(model);
    if(!context)return;
    NSString *title=PWRowText(PWIdentified(cell,@"Track.Row.Content.Title"));
    NSString *subtitle=PWRowText(PWIdentified(cell,@"Track.Row.Content.Subtitle"));
    if(!title.length || !subtitle.length)return;
    NSDictionary *info=[PWDownloadsBridge trackInfoFromModel:model uri:context[@"uri"] title:title subtitle:subtitle];
    if(button){
        objc_setAssociatedObject(button,&kTrackInfo,info,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(!objc_getAssociatedObject(button,&kTrackWatcher)){
            PWTrackMenuWatcher *watcher=[PWTrackMenuWatcher new];watcher.button=button;
            objc_setAssociatedObject(button,&kTrackWatcher,watcher,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:watcher action:@selector(tapped)];
            tap.cancelsTouchesInView=NO;tap.delaysTouchesEnded=NO;tap.delegate=watcher;
            [button addGestureRecognizer:tap];
            if([button isKindOfClass:UIControl.class])[(UIControl *)button addTarget:watcher action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside|UIControlEventPrimaryActionTriggered];
        }
    }
    if(![info[@"saved"] boolValue])return;
    UIView *art=PWIdentified(cell,@"Encore.ImageView");
    if(!art)return;
    if(!badge){
        badge=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        badge.tintColor=UIColor.systemGreenColor;badge.backgroundColor=UIColor.blackColor;
        badge.layer.cornerRadius=8;badge.clipsToBounds=YES;badge.userInteractionEnabled=NO;
        badge.isAccessibilityElement=YES;badge.accessibilityLabel=@"Téléchargé sur cet iPhone";
        objc_setAssociatedObject(cell,&kTrackBadge,badge,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell addSubview:badge];
    }
    CGRect frame=[cell convertRect:art.bounds fromView:art];
    badge.frame=CGRectMake(CGRectGetMaxX(frame)-16,CGRectGetMaxY(frame)-16,16,16);badge.alpha=1;
    [cell bringSubviewToFront:badge];
}

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if(PWDownloadsEnabled()) for(UIView *view=(UIView *)self; view; view=view.superview){
        if(objc_getAssociatedObject(view,&kTrackWatcher)){
            [PWDownloadsBridge selectMenuTrack:objc_getAssociatedObject(view,&kPlayingMenu) ? PWPlayingTrackInfo() : objc_getAssociatedObject(view,&kTrackInfo)];break;
        }
    }
    NSDictionary *context=objc_getAssociatedObject(self,&kContext);
    if(PWDownloadsEnabled()&&context){show((UIView *)self,context);return;}
    %orig;
}
%end
%hook _TtC35ListUXPlatform_FreeTierPlaylistImpl25ElementCollectionViewCell
- (void)layoutSubviews {
    %orig;
    PWApplyTrackRow((UIView *)self);
}
%end
// Same verified header class/identifier as Redesigned/Player/PlayerHeader.x.
// Shared placement also covers the classic Spotify appearance.
%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *button=PWIdentified(((UIViewController *)self).view,@"Context menu");
    if(!button || objc_getAssociatedObject(button,&kTrackWatcher))return;
    objc_setAssociatedObject(button,&kPlayingMenu,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PWTrackMenuWatcher *watcher=[PWTrackMenuWatcher new];watcher.button=button;
    objc_setAssociatedObject(button,&kTrackWatcher,watcher,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:watcher action:@selector(tapped)];
    tap.cancelsTouchesInView=NO;tap.delaysTouchesEnded=NO;tap.delegate=watcher;[button addGestureRecognizer:tap];
    if([button isKindOfClass:UIControl.class])[(UIControl *)button addTarget:watcher action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside|UIControlEventPrimaryActionTriggered];
}
%end
%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewDidLayoutSubviews {
    %orig;
    [PWDownloadsBridge installTrackMenu:(UIViewController *)self];
}
%end
%ctor {
    %init;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"spotifyglass.download.autoOffline":@YES,@"spotifyglass.download.audiusFallback":@YES}];
    dispatch_async(dispatch_get_main_queue(), ^{[PWDownloadsBridge startOfflineMonitor];});
    [NSNotificationCenter.defaultCenter addObserverForName:@"PWOfflinePlaybackStarting" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
        id<SPTPlayer> player=SGKaraokePlayer();
        if(player && !SGPlayerState().isPaused)[player pause:nil];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"PWDownloadDiagnostic" object:nil queue:nil usingBlock:^(NSNotification *note){
        NSString *event=note.userInfo[@"event"];
        if([event isKindOfClass:NSString.class]) {
            NSDictionary *details = [note.userInfo[@"details"] isKindOfClass:NSDictionary.class] ? note.userInfo[@"details"] : nil;
            PWEventDetails(@"download",event,[note.userInfo[@"code"] integerValue],details);
        }
    }];
}
