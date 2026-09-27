#import <Foundation/Foundation.h>
#import "PWProviderSupport.h"
#import "PWAppleParsing.h"

static NSUInteger checks;
static void check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        check(PWMatches(@"Été — LIVE", @"ete live"), @"accent and punctuation matching");
        check(!PWMatches(@"Song", @"Song (Live)"), @"do not silently select another edition");
        check(!PWMatches(@"", @""), @"empty titles do not match");
        check(!PWMatches((id)NSNull.null, @"song"), @"malformed text rejected");
        check(PWFragmentMatches(@"A line in the light", @"First verse\nA line in the light\nLast verse"), @"line in a multi-line annotation");
        check(!PWFragmentMatches(@"he", @"the"), @"short substring is not an annotation");
        check(!PWFragmentMatches(@"line in the light", @"outline in the lighthouse"), @"whole word matching");
        check(PWFragmentMatches(@"Été!", @"ete"), @"short exact annotation");
        check(!PWFragmentMatches(@"", @""), @"empty annotations rejected");
        check(PWAllowedAppleURL([NSURL URLWithString:@"https://mvod.itunes.apple.com/a"]), @"Apple CDN allowed");
        for (NSString *s in @[@"http://mvod.itunes.apple.com/a", @"https://itunes.apple.com.evil.test/a", @"https://evilitunes.apple.com/a", @"https://user:secret@itunes.apple.com/a", @"https://itunes.apple.com:444/a"]) {
            check(!PWAllowedAppleURL([NSURL URLWithString:s]), @"untrusted URL rejected");
        }
        NSURL *base = [NSURL URLWithString:@"https://mvod.itunes.apple.com/album/master.m3u8"];
        NSString *master = @"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=50,CODECS=\"hvc1\",RESOLUTION=480x640\nhevc.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=100,CODECS=\"avc1.64001f\",RESOLUTION=480x640,VIDEO-RANGE=SDR\nclear.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200,CODECS=\"avc1.64001f\",RESOLUTION=810x1080\nbig.m3u8\n";
        check([PWAppleVariant(master,base).lastPathComponent isEqualToString:@"clear.m3u8"], @"select a suitable AVC variant");
        check(!PWAppleVariant(@"not a playlist",base), @"invalid master rejected");
        NSString *media = @"#EXTM3U\n#EXT-X-MAP:URI=\"video.mp4\",BYTERANGE=\"123@0\"\n#EXTINF:2,\n#EXT-X-BYTERANGE:1000@123\nvideo.mp4\n#EXTINF:2,\n#EXT-X-BYTERANGE:1000@1123\nvideo.mp4\n#EXT-X-ENDLIST\n";
        check([PWAppleSingleFile(media,base).lastPathComponent isEqualToString:@"video.mp4"], @"clear single-file byte ranges");
        check(!PWAppleSingleFile([media stringByAppendingString:@"#EXT-X-KEY:METHOD=AES-128\n"],base), @"encrypted playlist rejected");
        check(!PWAppleSingleFile([media stringByAppendingString:@"other.mp4\n"],base), @"multi-file playlist rejected");
        check(!PWAppleSingleFile([media stringByReplacingOccurrencesOfString:@"#EXT-X-ENDLIST" withString:@""],base), @"live playlist rejected");
        check(!PWAppleSingleFile([media stringByReplacingOccurrencesOfString:@"video.mp4" withString:@"https://evil.test/video.mp4"],base), @"foreign media URL rejected");
        NSString *(^page)(id) = ^NSString *(id object) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
            return [NSString stringWithFormat:@"<script type=\"application/json\" id=\"serialized-server-data\">%@</script>", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        };
        id motion = @{@"dictionary":@{@"motionDetailSquare":@{@"video":base.absoluteString}}};
        check([PWAppleVideoFromPage(page(@[@{@"data":@{@"tallVideoArtwork":NSNull.null,@"videoArtwork":motion}}])) isEqual:base], @"square fallback when tall artwork is null");
        check(!PWAppleVideoFromPage(page(@[@{@"videoArtwork":NSNull.null}])), @"album without motion artwork");
        check(!PWAppleVideoFromPage(@"<html>Unavailable</html>"), @"service error HTML");
        check(!PWAppleVideoFromPage(nil), @"absent page");
        NSURL *query = PWQueryURL(@"https://api.genius.com/search",@{@"q":@"A&B + #é"});
        check([NSURLComponents componentsWithURL:query resolvingAgainstBaseURL:NO].queryItems.firstObject.value != nil, @"query generated");
        check([[NSURLComponents componentsWithURL:query resolvingAgainstBaseURL:NO].queryItems.firstObject.value isEqualToString:@"A&B + #é"], @"query characters round trip");
        NSLog(@"PASS: %lu provider checks", (unsigned long)checks);
    }
    return 0;
}
