#import "PWDownloads.h"

// Root view and legacy flow layout verified in the 9.1.78 executable.
// UIKit compositional layouts are handled without altering native item counts.
%hook _TtC28YourLibrary_YourLibraryXImpl15YourLibraryView
- (void)layoutSubviews { %orig; [PWDownloadsBridge installDownloadedLibraryFilter:(UIView *)self]; }
%end

%hook UICollectionViewFlowLayout
- (void)prepareLayout { %orig; [PWDownloadsBridge prepareDownloadedLibraryLayout:(id)self]; }
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibraryElements:(id)self rect:rect];
    return %orig;
}
- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)path {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibraryItem:(id)self path:path];
    return %orig;
}
- (UICollectionViewLayoutAttributes *)layoutAttributesForSupplementaryViewOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)path {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibrarySupplementary:(id)self kind:kind path:path];
    return %orig;
}
- (CGSize)collectionViewContentSize {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibrarySize:(id)self];
    return %orig;
}
%end
%hook _TtC21YourLibrary_CommonKit35YourLibraryCollectionViewFlowLayout
- (void)prepareLayout { %orig; [PWDownloadsBridge prepareDownloadedLibraryLayout:(id)self]; }
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibraryElements:(id)self rect:rect];
    return %orig;
}
- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)path {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibraryItem:(id)self path:path];
    return %orig;
}
%end
%hook UICollectionViewCompositionalLayout
- (void)prepareLayout { %orig; [PWDownloadsBridge prepareDownloadedLibraryLayout:(id)self]; }
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibraryElements:(id)self rect:rect];
    return %orig;
}
- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)path {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibraryItem:(id)self path:path];
    return %orig;
}
- (UICollectionViewLayoutAttributes *)layoutAttributesForSupplementaryViewOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)path {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibrarySupplementary:(id)self kind:kind path:path];
    return %orig;
}
- (CGSize)collectionViewContentSize {
    if([PWDownloadsBridge downloadedLibraryLayoutActive:(id)self])return [PWDownloadsBridge downloadedLibrarySize:(id)self];
    return %orig;
}
%end
%ctor { %init; }
