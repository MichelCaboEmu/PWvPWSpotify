#import "PWAppleParsing.h"
#import "PWProviderSupport.h"
static NSString *string(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }
static NSString *capture(NSString *s, NSString *pattern) {
    if (!s.length) return nil;
    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *m = [r firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    return m.numberOfRanges > 1 ? [s substringWithRange:[m rangeAtIndex:1]] : nil;
}
static NSString *video(id object, NSString *albumID) {
    if ([object isKindOfClass:NSDictionary.class]) {
        id descriptor=[object[@"contentDescriptor"] isKindOfClass:NSDictionary.class] ? object[@"contentDescriptor"] : @{};
        id identifiers=[descriptor isKindOfClass:NSDictionary.class] ? descriptor[@"identifiers"] : nil;
        NSString *itemID=[identifiers isKindOfClass:NSDictionary.class] ? string(identifiers[@"storeAdamID"]) : nil;
        BOOL header=[string(object[@"id"]) hasPrefix:@"album-detail-header - "] &&
            [string(descriptor[@"kind"]) isEqualToString:@"album"] && [itemID isEqualToString:albumID];
        if (header) for (NSString *key in @[@"tallVideoArtwork", @"videoArtwork"]) {
        id field = object[key];
        if ([field isKindOfClass:NSDictionary.class] && [field[@"dictionary"] isKindOfClass:NSDictionary.class]) {
            for (id value in [field[@"dictionary"] allValues]) if ([value isKindOfClass:NSDictionary.class]) {
                NSString *url = string(value[@"video"]);
                if (url.length) return url;
            }
        }
        }
        for (id value in [object allValues]) { NSString *found = video(value, albumID); if (found) return found; }
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) { NSString *found = video(value, albumID); if (found) return found; }
    }
    return nil;
}
NSURL *PWAppleVideoFromPage(NSString *html, NSString *albumID) {
    if (!albumID.length) return nil;
    NSString *json = capture(html, @"<script[^>]*id=[\"']serialized-server-data[\"'][^>]*>(.*?)</script>");
    id root = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    NSURL *url = [NSURL URLWithString:video(root, albumID) ?: @""];
    return PWAllowedAppleURL(url) ? url : nil;
}
NSURL *PWAppleVariant(NSString *playlist, NSURL *base) {
    if (![playlist hasPrefix:@"#EXTM3U"]) return nil;
    NSArray *lines = [playlist componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSURL *best = nil; NSInteger bestScore = NSIntegerMax;
    for (NSUInteger i = 0; i + 1 < lines.count; i++) {
        NSString *line = lines[i]; if (![line hasPrefix:@"#EXT-X-STREAM-INF:"] || ![line containsString:@"avc1"] || [line containsString:@"VIDEO-RANGE=PQ"]) continue;
        NSString *resolution = capture(line, @"RESOLUTION=([0-9]+x[0-9]+)");
        NSArray *size = [resolution componentsSeparatedByString:@"x"];
        if (size.count != 2) continue;
        NSInteger height = [size[1] integerValue]; if (height > 1080 || height < 200) continue;
        NSString *next = [lines[i + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSURL *url = [NSURL URLWithString:next relativeToURL:base].absoluteURL;
        NSInteger score = labs(height - 960);
        if (PWAllowedAppleURL(url) && score < bestScore) { best = url; bestScore = score; }
    }
    return best;
}
NSURL *PWAppleSingleFile(NSString *playlist, NSURL *base) {
    if (![playlist hasPrefix:@"#EXTM3U"] || ![playlist containsString:@"#EXT-X-ENDLIST"] ||
        [playlist containsString:@"#EXT-X-KEY:"] || [playlist containsString:@"#EXT-X-SESSION-KEY:"]) return nil;
    NSURL *file = nil;
    NSString *map = capture(playlist, @"#EXT-X-MAP:URI=\"([^\"]+)\"");
    for (NSString *raw in [playlist componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSURL *candidate = [NSURL URLWithString:line relativeToURL:base].absoluteURL;
        if (!PWAllowedAppleURL(candidate) || ![candidate.pathExtension.lowercaseString isEqualToString:@"mp4"]) return nil;
        if (file && ![file isEqual:candidate]) return nil;
        file = candidate;
    }
    if (map && ![[NSURL URLWithString:map relativeToURL:base].absoluteURL isEqual:file]) return nil;
    return file;
}
