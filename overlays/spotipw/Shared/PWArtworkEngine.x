#import "PWArtworkEngine.h"
#import "PWAppleArtwork.h"
#import "PWLockScreenArtwork.h"
#import "Core/SGCore.h"
#import "Core/PWDiagnostics.h"
#import "Core/PWProviderSupport.h"
#import "Shared/Player/PlayerState.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static dispatch_queue_t renderQueue;
static NSString *cacheDirectory;
static NSMutableDictionary *entries;
static NSObject *entryLock;
static NSString *forceKey;
static NSString *statusText = @"En attente de lecture";
static NSString *lastSeen;
static NSString *identity(NSDictionary *info) {
    NSString *title = info[MPMediaItemPropertyTitle];
    if (![title isKindOfClass:NSString.class] || !title.length) return nil;
    NSString *seed = [NSString stringWithFormat:@"%@|%@|%@|%@", title, [NSString stringWithFormat:@"%@|%@", info[@"pw.originalArtist"] ?: info[MPMediaItemPropertyArtist] ?: @"", info[MPMediaItemPropertyAlbumTitle] ?: @""],
        info[MPMediaItemPropertyPlaybackDuration] ?: @0, info[MPNowPlayingInfoPropertyExternalContentIdentifier] ?: @""];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; NSData *bytes = [seed dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
    NSMutableString *key = [NSMutableString string]; for (int i=0;i<16;i++) [key appendFormat:@"%02x",hash[i]];
    return key;
}
static UIImage *frame(UIImage *cover, double phase, CVPixelBufferRef buffer) {
    const size_t width=480, height=640;
    void *pixels = NULL; size_t stride=width*4;
    if (buffer) { CVPixelBufferLockBaseAddress(buffer, 0); pixels = CVPixelBufferGetBaseAddress(buffer); stride=CVPixelBufferGetBytesPerRow(buffer); }
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels,width,height,8,stride,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(color);
    if (!context) { if(buffer) CVPixelBufferUnlockBaseAddress(buffer,0); return nil; }
    CGContextSetRGBFillColor(context,0.04,0.04,0.04,1); CGContextFillRect(context,CGRectMake(0,0,width,height));
    CGImageRef art=cover.CGImage;
    if (art) {
        double w=CGImageGetWidth(art), h=CGImageGetHeight(art);
        double scale=MAX(width/w,height/h)*(1.10+0.025*sin(phase));
        double x=(width-w*scale)/2+8*sin(phase), y=(height-h*scale)/2+8*cos(phase);
        CGContextSetInterpolationQuality(context,kCGInterpolationHigh);
        // Pixel buffers and UIImage previews use the same orientation and crop.
        CGContextDrawImage(context,CGRectMake(x,y,w*scale,h*scale),art);
    }
    UIImage *result=nil;
    if (!buffer) { CGImageRef image=CGBitmapContextCreateImage(context); if(image){result=[UIImage imageWithCGImage:image];CGImageRelease(image);} }
    CGContextRelease(context); if(buffer)CVPixelBufferUnlockBaseAddress(buffer,0); return result;
}
static void generate(UIImage *cover, NSURL *url, void (^done)(NSURL *)) {
    dispatch_async(renderQueue, ^{
        __block BOOL delivered=NO;
        void (^finish)(NSURL *)=^(NSURL *file){
            if(delivered)return;delivered=YES;
            if(!file)[NSFileManager.defaultManager removeItemAtURL:url error:nil];
            dispatch_async(dispatch_get_main_queue(),^{done(file);});
        };
        NSError *error=nil;
        AVAssetWriter *writer=[[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
        NSDictionary *settings=@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@480,AVVideoHeightKey:@640,
            AVVideoCompressionPropertiesKey:@{AVVideoAverageBitRateKey:@1200000,AVVideoMaxKeyFrameIntervalKey:@24}};
        AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
        AVAssetWriterInputPixelBufferAdaptor *adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferWidthKey:@480,(id)kCVPixelBufferHeightKey:@640,(id)kCVPixelBufferCGImageCompatibilityKey:@YES,(id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES}];
        if (!writer || ![writer canAddInput:input]) { finish(nil);return; }
        [writer addInput:input]; if(![writer startWriting]){finish(nil);return;}
        [writer startSessionAtSourceTime:kCMTimeZero];
        __block NSInteger index=0; __block BOOL ended=NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),renderQueue,^{
            if(delivered)return;ended=YES;[writer cancelWriting];finish(nil);
        });
        [input requestMediaDataWhenReadyOnQueue:renderQueue usingBlock:^{
            if(ended)return;
            while(input.readyForMoreMediaData && index<144){
                @autoreleasepool {
                    CVPixelBufferRef pixel=NULL;
                    CVReturn result=adaptor.pixelBufferPool ? CVPixelBufferPoolCreatePixelBuffer(NULL,adaptor.pixelBufferPool,&pixel) : kCVReturnError;
                    if(result!=kCVReturnSuccess){ended=YES;[writer cancelWriting];finish(nil);return;}
                    frame(cover,2*M_PI*index/144.0,pixel);
                    BOOL ok=[adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(index,24)];CVPixelBufferRelease(pixel);
                    if(!ok){ended=YES;[writer cancelWriting];finish(nil);return;}
                    index++;
                }
            }
            if(index==144){ended=YES;[input markAsFinished];[writer endSessionAtSourceTime:CMTimeMake(144,24)];
                [writer finishWritingWithCompletionHandler:^{dispatch_async(renderQueue,^{finish(writer.status==AVAssetWriterStatusCompleted?url:nil);});}];}
        }];
    });
}
@interface PWArtworkEntry : NSObject
@property(nonatomic,copy) NSString *key,*artworkID,*album,*artist,*source;
@property(nonatomic,strong) UIImage *cover,*preview;
@property(nonatomic,strong) NSURL *file;
@property(nonatomic,strong) NSMutableArray *callbacks;
@property(nonatomic) BOOL loading,apple,generated;
@property(nonatomic) NSInteger attempts;
@property(nonatomic) NSTimeInterval failedAt;
- (void)request:(void (^)(NSURL *))completion;
@end
@implementation PWArtworkEntry
- (void)dealloc { if(_file)[NSFileManager.defaultManager removeItemAtURL:_file error:nil]; }
- (void)finish:(NSURL *)file preview:(UIImage *)preview source:(NSString *)source {
    self.loading=NO; self.file=file; if(preview)self.preview=preview; self.source=source;
    if(!file)self.failedAt=NSDate.date.timeIntervalSince1970;
    NSString *currentKey=identity(MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo);
    @synchronized(entryLock){
        if(entries[self.key]==self && [self.key isEqualToString:currentKey]) statusText=source;
    }
    PWEvent(@"artwork",file?@"asset_ready":@"asset_failed",self.attempts);
    NSArray *callbacks=[self.callbacks copy];[self.callbacks removeAllObjects];
    for(void (^callback)(NSURL *) in callbacks)callback(file);
}
- (void)fallback {
    if(!self.generated){[self finish:nil preview:nil source:@"Aucune vidéo disponible"];return;}
    NSURL *url=[NSURL fileURLWithPath:[cacheDirectory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mp4"]]];
    generate(self.cover,url,^(NSURL *file){[self finish:file preview:nil source:file?@"Animation de la pochette":@"Échec de génération — réessayer"];});
}
- (void)request:(void (^)(NSURL *))completion {
    // Called on the main queue. Keep URL/preview callbacks bounded and coalesced.
    if(self.file && [NSFileManager.defaultManager fileExistsAtPath:self.file.path]){completion(self.file);return;}
    if(self.attempts>=2 && NSDate.date.timeIntervalSince1970-self.failedAt<30){completion(nil);return;}
    [self.callbacks addObject:[completion copy]];if(self.loading)return;
    self.loading=YES;self.attempts++;PWEvent(@"artwork",@"asset_requested",self.attempts);
    if(!self.apple){[self fallback];return;}
    NSURL *url=[NSURL fileURLWithPath:[cacheDirectory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mp4"]]];
    PWAppleArtwork(self.album,self.artist,url,^(NSURL *file,UIImage *preview){
        if(file){[self finish:file preview:preview source:@"Apple Music"];return;}[self fallback];
    });
}
@end
static BOOL nativeArtwork(NSDictionary *info) {
    if(@available(iOS 26.0,*)) {
        for(NSString *field in @[MPNowPlayingInfoProperty3x4AnimatedArtwork,MPNowPlayingInfoProperty1x1AnimatedArtwork]) {
            id art=info[field];
            if([art isKindOfClass:MPMediaItemAnimatedArtwork.class] && ![((MPMediaItemAnimatedArtwork *)art).artworkID hasPrefix:@"pw:"])return YES;
        }
    }
    return NO;
}
static NSDictionary *decorate(NSDictionary *info);
static void prepare(NSDictionary *original) {
    if(!PWLockScreenArtworkEnabled())return;
    NSString *key=identity(original);if(!key || ![key isEqualToString:identity(MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo)])return;
    NSInteger mode=SGInt(PWKeyArtworkMode,0);
    BOOL force=[key isEqualToString:forceKey];
    if(mode==3 || (mode==0 && nativeArtwork(MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo) && !force))return;
    @synchronized(entryLock){if(entries[key])return;}
    MPMediaItemArtwork *art=original[MPMediaItemPropertyArtwork];
    if(![art isKindOfClass:MPMediaItemArtwork.class])return;
    UIImage *cover=[art imageWithSize:CGSizeMake(640,640)];if(!cover)return;
    PWArtworkEntry *entry=[PWArtworkEntry new];entry.key=key;entry.cover=cover;entry.preview=frame(cover,0,NULL);
    entry.artworkID=[@"pw:" stringByAppendingString:NSUUID.UUID.UUIDString];entry.callbacks=[NSMutableArray array];
    entry.album=[original[MPMediaItemPropertyAlbumTitle] isKindOfClass:NSString.class]?original[MPMediaItemPropertyAlbumTitle]:@"";
    SPTPlayerTrack *track=SGPlayerState().track;
    entry.artist=PWMatches(track.trackTitle,original[MPMediaItemPropertyTitle])?track.artistName:(original[@"pw.originalArtist"] ?: original[MPMediaItemPropertyArtist]);
    entry.apple=mode!=2 && SGEnabled(PWKeyAppleArtwork);entry.generated=SGEnabled(PWKeyGeneratedArtwork);
    if(!entry.apple&&!entry.generated)return;
    @synchronized(entryLock){
        // Entries retain only the latest tracks; active system artwork retains its
        // own entry independently, so its file stays valid for its lifetime.
        if(entries.count>8){for(NSString *old in entries.allKeys)if(![old isEqualToString:key])[entries removeObjectForKey:old];}
        entries[key]=entry;
    }
    statusText=@"Prêt — ouvrir la pochette sur l’écran verrouillé";
    NSDictionary *current=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    if([key isEqualToString:identity(current)])MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=decorate(current);
}
static NSDictionary *decorate(NSDictionary *info) {
    if(!PWLockScreenArtworkEnabled() || !info)return info;
    if(@available(iOS 26.0,*)){
        NSString *key=identity(info);if(!key)return info;
        NSInteger mode=SGInt(PWKeyArtworkMode,0);
        BOOL native=nativeArtwork(info);
        BOOL forced;PWArtworkEntry *entry;
        @synchronized(entryLock){forced=[key isEqualToString:forceKey];entry=entries[key];}
        if(mode==3 || (mode==0&&native&&!forced)){
            dispatch_async(dispatch_get_main_queue(),^{if(![lastSeen isEqualToString:key]){lastSeen=key;statusText=native?@"Vidéo fournie par Spotify":@"Spotify ne fournit pas de vidéo pour cette piste";PWEvent(@"artwork",@"spotify_metadata",0);}});
            return info;
        }
        if(!entry){dispatch_async(dispatch_get_main_queue(),^{prepare(info);});return info;}
        MPMediaItemAnimatedArtwork *artwork=[[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:entry.artworkID
            previewImageRequestHandler:^(CGSize size,void (^completion)(UIImage *)){
                dispatch_async(dispatch_get_main_queue(),^{completion(entry.preview);});
            } videoAssetFileURLRequestHandler:^(CGSize size,void (^completion)(NSURL *)){
                dispatch_async(dispatch_get_main_queue(),^{[entry request:completion];});
            }];
        NSMutableDictionary *updated=[info mutableCopy];
        [updated removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        updated[MPNowPlayingInfoProperty3x4AnimatedArtwork]=artwork;
        return updated;
    }
    return info;
}
NSString *PWArtworkEngineStatus(void){return statusText;}
void PWRetryArtwork(void){
    NSDictionary *current=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;NSString *key=identity(current);if(!key)return;
    @synchronized(entryLock){forceKey=key;[entries removeObjectForKey:key];}
    if(@available(iOS 26.0,*)){
        NSMutableDictionary *retry=[current mutableCopy];[retry removeObjectForKey:MPNowPlayingInfoProperty3x4AnimatedArtwork];[retry removeObjectForKey:MPNowPlayingInfoProperty1x1AnimatedArtwork];
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=retry;
        prepare(retry);PWEvent(@"artwork",@"manual_retry",0);
    }
}
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    NSDictionary *decorated = decorate(info);
    %orig(decorated);
}
%end
%ctor {
    entryLock=[NSObject new];entries=[NSMutableDictionary dictionary];renderQueue=dispatch_queue_create("pw.artwork.render",DISPATCH_QUEUE_SERIAL);
    cacheDirectory=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"PWArtwork"];
    [NSFileManager.defaultManager createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    // A new process publishes new artwork IDs. No previous process's asset remains
    // part of this process's now playing info; prune only at this safe boundary.
    for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:cacheDirectory error:nil])
        [NSFileManager.defaultManager removeItemAtPath:[cacheDirectory stringByAppendingPathComponent:file] error:nil];
    if(!PWLockScreenArtworkEnabled())return;
    %init;
}
