#import "PWProviderSupport.h"
NSString *PWNormalize(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *s = [[text stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]] lowercaseString];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}
BOOL PWMatches(NSString *expected, NSString *actual) {
    NSString *a = PWNormalize(expected), *b = PWNormalize(actual);
    return a.length && [a isEqualToString:b];
}
// Lyrics providers disagree about apostrophes and line breaks. Keep song-title
// matching strict; only lyric fragments use this normalization.
static NSString *lyricText(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSRegularExpression *apostrophe = [NSRegularExpression regularExpressionWithPattern:@"(?<=\\p{L})['’ʼ](?=\\p{L})" options:0 error:nil];
    return PWNormalize([apostrophe stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@""]);
}
BOOL PWFragmentMatches(NSString *line, NSString *fragment) {
    NSString *a = lyricText(line), *b = lyricText(fragment);
    if (!a.length || !b.length) return NO;
    if ([a isEqualToString:b]) return YES;
    // An annotation can cover a verse OR just a phrase inside the selected line.
    // Require whole words and a meaningful phrase, never an incidental substring.
    NSString *shorter = a.length <= b.length ? a : b;
    NSString *longer = a.length <= b.length ? b : a;
    NSUInteger words = [shorter componentsSeparatedByString:@" "].count;
    if (shorter.length < 6 || (words < 2 && shorter.length < 8)) return NO;
    return [[NSString stringWithFormat:@" %@ ", longer] containsString:[NSString stringWithFormat:@" %@ ", shorter]];
}
BOOL PWAllowedAppleURL(NSURL *url) {
    NSString *h = url.host.lowercaseString;
    return !url.user.length && !url.password.length && (!url.port || url.port.integerValue == 443) && [url.scheme.lowercaseString isEqualToString:@"https"] &&
        ([h isEqualToString:@"music.apple.com"] || [h isEqualToString:@"itunes.apple.com"] ||
         [h hasSuffix:@".itunes.apple.com"] || [h isEqualToString:@"mzstatic.com"] || [h hasSuffix:@".mzstatic.com"]);
}
NSURL *PWQueryURL(NSString *base, NSDictionary<NSString *, NSString *> *params) {
    NSURLComponents *c = [NSURLComponents componentsWithString:base];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in params) [items addObject:[NSURLQueryItem queryItemWithName:key value:params[key]]];
    c.queryItems = items; return c.URL;
}
// No cookies or Spotify authorization headers ever leave through these sessions.
@interface PWFetchTask : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic) NSUInteger limit;
@property (nonatomic) NSInteger status;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) NSString *originHost;
@property (nonatomic) BOOL apple;
@property (nonatomic, copy) void (^done)(NSData *, NSInteger);
@end
@implementation PWFetchTask
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    BOOL allowed = [request.URL.scheme isEqualToString:@"https"] &&
        (self.apple ? PWAllowedAppleURL(request.URL) : [request.URL.host isEqualToString:self.originHost]);
    completionHandler(allowed ? request : nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.status = [(NSHTTPURLResponse *)response statusCode];
    completionHandler(self.status == 200 && response.expectedContentLength <= (int64_t)self.limit ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (self.data.length + data.length > self.limit) { [task cancel]; return; }
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    void (^done)(NSData *, NSInteger) = self.done;
    NSData *data = !error && self.status == 200 ? [self.data copy] : nil;
    NSInteger status = error && self.status == 0 ? error.code : self.status;
    self.done = nil; [session finishTasksAndInvalidate]; self.session = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(data, status); });
}
@end
void PWFetch(NSURL *url, NSDictionary *headers, NSUInteger maxBytes, void (^done)(NSData *, NSInteger)) {
    if (!url || ![url.scheme isEqualToString:@"https"]) { dispatch_async(dispatch_get_main_queue(), ^{ done(nil, -1); }); return; }
    PWFetchTask *delegate = [PWFetchTask new];
    delegate.data = [NSMutableData data]; delegate.limit = maxBytes; delegate.done = done;
    delegate.originHost = url.host; delegate.apple = PWAllowedAppleURL(url);
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 18;
    c.HTTPCookieStorage = nil; c.HTTPShouldSetCookies = NO; c.URLCache = nil;
    delegate.session = [NSURLSession sessionWithConfiguration:c delegate:delegate delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.allHTTPHeaderFields = headers;
    [[delegate.session dataTaskWithRequest:request] resume];
}
void PWJSON(NSURL *url, NSDictionary *headers, void (^done)(NSDictionary *, NSInteger)) {
    PWFetch(url, headers, 3 * 1024 * 1024, ^(NSData *data, NSInteger status) {
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        done([object isKindOfClass:NSDictionary.class] ? object : nil, status);
    });
}
