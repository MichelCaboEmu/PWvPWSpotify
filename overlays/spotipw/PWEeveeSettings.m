#import "Core/SGCore.h"
#import "PWEeveeSettings.h"
#import <objc/message.h>

SGModRow *PWEeveeSettingsRow(void) {
    return SGWithSymbol(SGActionRow(@"Compléments Eevee", @"SponsorBlock, partage, mélange et icônes", ^{
        UIViewController *presenter = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) presenter = window.rootViewController;
        }
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        Class bridge = NSClassFromString(@"PWEeveeBridge");
        SEL selector = NSSelectorFromString(@"presentExtrasFrom:");
        if (presenter && [bridge respondsToSelector:selector]) {
            ((void (*)(id, SEL, UIViewController *))objc_msgSend)(bridge, selector, presenter);
        } else if (presenter) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Module Eevee absent" message:@"Réinstalle l’IPA PWvPWSpotify complet." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [presenter presentViewController:alert animated:YES completion:nil];
        }
    }), @"puzzlepiece.extension");
}
