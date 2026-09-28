#import "PWDownloads.h"
#import "Core/SGCore.h"
#import "Core/PWDiagnostics.h"
#import "Shared/Lyrics/Lyrics.h"
#import <objc/message.h>

static char kContext, kFallback;
BOOL PWDownloadsEnabled(void) { return [NSUserDefaults.standardUserDefaults integerForKey:PWKeyDownloadSource] != 2; }

// Selectors and object return encodings verified in the supplied 9.1.78 executable.
static id objectGetter(id object, NSString *name) {
    SEL sel=NSSelectorFromString(name);
    if (![object respondsToSelector:sel]) return nil;
    NSMethodSignature *signature=[object methodSignatureForSelector:sel];
    if (signature.numberOfArguments!=2 || signature.methodReturnType[0]!='@') return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,sel);
}
static id modelFor(UIView *view) {
    for(UIResponder *r=view;r;r=r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        if (![NSStringFromClass(r.class) containsString:@"FreeTierPlaylist"]) return nil;
        return objectGetter(objectGetter(r,@"headerController"),@"defaultHeaderViewModel");
    }
    return nil;
}
static NSDictionary *contextFor(id model) {
    id url=objectGetter(model,@"playlistURL");
    NSString *uri=[url isKindOfClass:NSURL.class]?[url absoluteString]:([url isKindOfClass:NSString.class]?url:nil);
    id title=objectGetter(model,@"playlistName");
    if(!uri.length)return nil;
    return @{@"uri":uri,@"title":[title isKindOfClass:NSString.class]?title:@"Playlist"};
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
    [PWDownloadsBridge presentFrom:vc playlistURI:context[@"uri"] title:context[@"title"] authorization:SGKaraokeSpotifyAuthorization()];
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

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    NSDictionary *context=objc_getAssociatedObject(self,&kContext);
    if(PWDownloadsEnabled()&&context){show((UIView *)self,context);return;}
    %orig;
}
%end
%ctor {
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:@"PWDownloadDiagnostic" object:nil queue:nil usingBlock:^(NSNotification *note){
        NSString *event=note.userInfo[@"event"];
        if([event isKindOfClass:NSString.class])PWEvent(@"download",event,[note.userInfo[@"code"] integerValue]);
    }];
}
