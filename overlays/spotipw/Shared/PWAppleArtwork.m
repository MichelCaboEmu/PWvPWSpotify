#import "PWAppleArtwork.h"
#import "Core/PWProviderSupport.h"
#import "Core/PWDiagnostics.h"
#import <AVFoundation/AVFoundation.h>

#import "Core/PWAppleParsing.h"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSString *string(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }
static void normalizeVideo(NSURL *source, NSURL *destination, void (^done)(NSURL *, UIImage *)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration", @"playable"] completionHandler:^{
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded || !asset.playable || asset.hasProtectedContent) {
            [NSFileManager.defaultManager removeItemAtURL:source error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, nil); }); return;
        }
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        double duration = CMTimeGetSeconds(asset.duration);
        if (!track || !isfinite(duration) || duration <= 0 || duration > 30) {
            [NSFileManager.defaultManager removeItemAtURL:source error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, nil); }); return;
        }
        // Exact 3:4 output, regardless of the source's rounding (e.g. 486x648).
        CGSize target = CGSizeMake(720, 960);
        CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, track.naturalSize}, track.preferredTransform);
        if (!isfinite(bounds.size.width) || !isfinite(bounds.size.height) || fabs(bounds.size.width) < 1 || fabs(bounds.size.height) < 1) {
            [NSFileManager.defaultManager removeItemAtURL:source error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, nil); }); return;
        }
        CGFloat scale = MAX(target.width / fabs(bounds.size.width), target.height / fabs(bounds.size.height));
        CGAffineTransform transform = CGAffineTransformConcat(track.preferredTransform, CGAffineTransformMakeTranslation(-bounds.origin.x, -bounds.origin.y));
        transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale, scale));
        transform = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation((target.width - fabs(bounds.size.width) * scale) / 2, (target.height - fabs(bounds.size.height) * scale) / 2));
        AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
        [layer setTransform:transform atTime:kCMTimeZero];
        AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration); instruction.layerInstructions = @[layer];
        AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
        composition.renderSize = target; composition.frameDuration = CMTimeMake(1, 30); composition.instructions = @[instruction];
        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
        if (!exporter) { [NSFileManager.defaultManager removeItemAtURL:source error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, nil); }); return; }
        exporter.outputURL = destination; exporter.outputFileType = AVFileTypeMPEG4; exporter.videoComposition = composition;
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            UIImage *preview = nil;
            if (exporter.status == AVAssetExportSessionStatusCompleted) {
                AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset URLAssetWithURL:destination options:nil]];
                generator.appliesPreferredTrackTransform = YES;
                CGImageRef image = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:nil];
                if (image) { preview = [UIImage imageWithCGImage:image]; CGImageRelease(image); }
            }
            [NSFileManager.defaultManager removeItemAtURL:source error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ done(preview ? destination : nil, preview); });
        }];
    }];
}
void PWAppleArtwork(NSString *album, NSString *artist, NSURL *destination, void (^done)(NSURL *, UIImage *)) {
    if (!album.length || !artist.length) { done(nil, nil); return; }
    __block BOOL finished = NO;
    void (^finish)(NSURL *, UIImage *) = ^(NSURL *url, UIImage *image) {
        if (finished) { if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil]; return; }
        finished = YES;
        if (!url) [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
        done(url, image);
    };
    // Bound the whole search/download/export, leaving time for local fallback.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(nil, nil); });
    NSURL *search = PWQueryURL(@"https://itunes.apple.com/search", @{@"term":[NSString stringWithFormat:@"%@ %@", artist, album], @"entity":@"album", @"limit":@"8", @"country":@"US"});
    PWJSON(search, nil, ^(NSDictionary *root, NSInteger status) {
        if (finished) return;
        NSURL *page = nil; NSString *albumID = nil;
        id results = root[@"results"];
        if ([results isKindOfClass:NSArray.class]) for (id item in results) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            if (PWMatches(album, string(item[@"collectionName"])) && PWMatches(artist, string(item[@"artistName"]))) {
                page = [NSURL URLWithString:string(item[@"collectionViewUrl"]) ?: @""];
                if ([item[@"collectionId"] isKindOfClass:NSNumber.class]) albumID = [item[@"collectionId"] stringValue];
                break;
            }
        }
        if (!PWAllowedAppleURL(page) || !albumID.length) { PWEvent(@"apple", @"no_album_match", status); finish(nil,nil); return; }
        PWFetch(page, nil, 3 * 1024 * 1024, ^(NSData *data, NSInteger code) {
            if (finished) return;
            NSURL *master = PWAppleVideoFromPage([[NSString alloc] initWithData:data ?: NSData.data encoding:NSUTF8StringEncoding], albumID);
            if (!master) { PWEvent(@"apple", @"no_public_video", code); finish(nil,nil); return; }
            PWFetch(master, nil, 256 * 1024, ^(NSData *bytes, NSInteger s) {
                if (finished) return;
                NSURL *variant = PWAppleVariant([[NSString alloc] initWithData:bytes ?: NSData.data encoding:NSUTF8StringEncoding], master);
                if (!variant) { PWEvent(@"apple", @"unsupported_master", s); finish(nil,nil); return; }
                PWFetch(variant, nil, 256 * 1024, ^(NSData *media, NSInteger ss) {
                    if (finished) return;
                    NSURL *file = PWAppleSingleFile([[NSString alloc] initWithData:media ?: NSData.data encoding:NSUTF8StringEncoding], variant);
                    if (!file) { PWEvent(@"apple", @"unsupported_media", ss); finish(nil,nil); return; }
                    PWFetch(file, nil, 20 * 1024 * 1024, ^(NSData *videoData, NSInteger result) {
                        if (finished) return;
                        if (!videoData) { PWEvent(@"apple", @"download_failed", result); finish(nil,nil); return; }
                        NSURL *temp = [destination URLByAppendingPathExtension:@"source.mp4"];
                        if (![videoData writeToURL:temp options:NSDataWritingAtomic error:nil]) { finish(nil,nil); return; }
                        normalizeVideo(temp, destination, ^(NSURL *local, UIImage *preview) {
                            if (!local) [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
                            PWEvent(@"apple", local ? @"video_ready" : @"export_failed", 0);
                            finish(local, preview);
                        });
                    });
                });
            });
        });
    });
}
