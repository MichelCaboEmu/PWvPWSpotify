#import <Foundation/Foundation.h>
NSString *PWNormalize(NSString *text);
BOOL PWMatches(NSString *expected, NSString *actual);
BOOL PWAllowedAppleURL(NSURL *url);
NSURL *PWQueryURL(NSString *base, NSDictionary<NSString *, NSString *> *params);
void PWFetch(NSURL *url, NSDictionary *headers, NSUInteger maxBytes, void (^done)(NSData *, NSInteger));
void PWJSON(NSURL *url, NSDictionary *headers, void (^done)(NSDictionary *, NSInteger));

BOOL PWFragmentMatches(NSString *line, NSString *fragment);
