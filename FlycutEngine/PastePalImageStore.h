//
//  PastePalImageStore.h
//  PastePal
//
//  图片剪贴板的磁盘存储：按 SHA-256 命名、原子写入、缩略图与粘贴格式生成。
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class FlycutClipping;

@interface PastePalImageStore : NSObject {
// 图片文件根目录，默认 ~/Library/Application Support/PastePal/Images
    NSString *rootDirectory;
// 缩略图/预览缓存，按 hash 与最大边长索引
    NSCache *imageCache;
// 粘贴格式缓存，避免每次粘贴重复编码大图
    NSCache *representationCache;
// 串行队列，保证写入与孤儿清扫互斥
    dispatch_queue_t ioQueue;
}

// 测试可注入临时目录，避免污染真实的 Application Support
-(id) initWithRootDirectory:(NSString *)directory;
-(NSString *) rootDirectory;

// SHA-256 十六进制摘要，用于图片去重
+(NSString *) sha256HexForData:(NSData *)data;
// UTI 到存储扩展名的映射：png/tiff/jpeg/heic
+(NSString *) fileExtensionForUTI:(NSString *)uti;
// 读取图片像素尺寸；数据无效时返回 NO
+(BOOL) pixelSizeForImageData:(NSData *)data width:(int *)width height:(int *)height;

// 原子写入，返回文件名；相同 hash 已存在时直接复用
-(NSString *) saveData:(NSData *)data hash:(NSString *)hash uti:(NSString *)uti error:(NSError **)error;
-(NSData *) dataForClipping:(FlycutClipping *)clipping;
-(BOOL) fileExistsForImageFile:(NSString *)file;
-(NSString *) pathForImageFile:(NSString *)file;

// 生成等比缩略图/预览图；maxPixelSize 为最大边长（像素）
-(NSImage *) thumbnailForClipping:(FlycutClipping *)clipping maxPixelSize:(NSInteger)maxPixelSize;
-(NSImage *) imageForClipping:(FlycutClipping *)clipping maxPixelSize:(NSInteger)maxPixelSize;

// 返回 类型 -> NSData 的粘贴板表示，包含 PNG/TIFF/JPEG/HEIC 中可成功生成的格式
-(NSDictionary *) pasteboardRepresentationsForClipping:(FlycutClipping *)clipping;

// mark-and-sweep：删除不被引用的图片文件；minimumAge 用于避开正在写入的新文件
-(void) deleteUnreferencedFilesKeepingHashes:(NSSet *)hashes olderThan:(NSTimeInterval)minimumAge;

@end
