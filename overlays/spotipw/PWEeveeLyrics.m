// GPL-3.0. Data-only bridge into Eevee's original Genius/PetitLyrics repositories.
#import "Core/SGCore.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import <objc/message.h>

static void askEevee(NSString *provider, SGLyricsQuery *query, void (^done)(SGLyricsResult *)) {
    Class bridge = NSClassFromString(@"PWEeveeBridge");
    SEL selector = NSSelectorFromString(@"fetchLyrics:query:completion:");
    if (!bridge || ![bridge respondsToSelector:selector]) { done(nil); return; }
    NSDictionary *search = @{@"title": query.title ?: @"", @"artist": query.artist ?: @"", @"trackID": query.trackID ?: @""};
    void (^reply)(NSDictionary *) = ^(NSDictionary *answer) {
        if (![answer isKindOfClass:NSDictionary.class]) { done(nil); return; }
        NSArray *texts = answer[@"texts"], *starts = answer[@"starts"];
        if (![texts isKindOfClass:NSArray.class] || !texts.count ||
            ![starts isKindOfClass:NSArray.class] || starts.count != texts.count) { done(nil); return; }
        for (id text in texts) if (![text isKindOfClass:NSString.class]) { done(nil); return; }
        for (id start in starts) if (![start isKindOfClass:NSNumber.class]) { done(nil); return; }
        SGLyricsResult *result = [SGLyricsResult new];
        result.provider = provider;
        result.synced = [answer[@"synced"] boolValue];
        result.wordTimed = NO; // Eevee's Petit repository exposes line starts only.
        result.texts = texts;
        result.starts = starts;
        result.karaokeLines = result.synced ? SGKaraokeEstimatedLines(starts, texts) : SGKaraokeStaticLines(texts);
        result.title = query.title;
        result.artist = query.artist;
        done(result);
    };
    ((void (*)(id, SEL, NSString *, NSDictionary *, void (^)(NSDictionary *)))objc_msgSend)(bridge, selector, provider, search, reply);
}
SGLyricsAsk PWEeveeGeniusAsk = ^(SGLyricsQuery *q, void (^done)(SGLyricsResult *)) { askEevee(@"genius", q, done); };
SGLyricsAsk PWEeveePetitAsk = ^(SGLyricsQuery *q, void (^done)(SGLyricsResult *)) { askEevee(@"petitlyrics", q, done); };
