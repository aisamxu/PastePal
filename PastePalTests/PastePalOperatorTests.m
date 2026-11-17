//
//  PastePalOperatorTests.m
//  PastePalTests
//
//  图片历史的去重、统一条数窗口、容量淘汰、收藏保护与持久化测试。
//

#import <XCTest/XCTest.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import "FlycutOperator.h"
#import "FlycutEngine/PastePalImageStore.h"
#import "FlycutEngine/FlycutClipping.h"

// 测试会临时改写的偏好键，setUp 时快照、tearDown 时恢复
static NSArray *PastePalTestDefaultKeys(void)
{
    return [NSArray arrayWithObjects:
            @"rememberNum",
            @"favoritesRememberNum",
            @"savePreference",
            @"removeDuplicates",
            @"pasteMovesToTop",
            @"imageHistoryMaxBytes",
            @"imageMaxItemBytes",
            @"stifleRememberResizeWarning",
            @"store",
            nil];
}

// 用 CoreGraphics 生成纯色 PNG，保证测试不依赖外部图片资源
static NSData *PastePalTestPNGData(int width, int height, CGFloat red, CGFloat green, CGFloat blue)
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, 0, colorSpace,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return nil;
    }
    CGContextSetRGBFillColor(context, red, green, blue, 1.0);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    // 叠加逐像素噪点，避免纯色 PNG 被压得过小，容量/上限测试才有意义
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            CGFloat fx = (CGFloat)((x * 37 + y * 17 + (int)(red * 255)) % 256) / 255.0;
            CGFloat fy = (CGFloat)((x * 11 + y * 29 + (int)(green * 255)) % 256) / 255.0;
            CGFloat fz = (CGFloat)((x * 23 + y * 41 + (int)(blue * 255)) % 256) / 255.0;
            CGContextSetRGBFillColor(context, fx, fy, fz, 1.0);
            CGContextFillRect(context, CGRectMake(x, y, 1, 1));
        }
    }
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    if (destination == NULL) {
        CGImageRelease(cgImage);
        return nil;
    }
    CGImageDestinationAddImage(destination, cgImage, NULL);
    BOOL succeeded = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(cgImage);
    return succeeded ? data : nil;
}

@interface PastePalOperatorTests : XCTestCase {
    NSString *tempDirectory;
    PastePalImageStore *imageStore;
    FlycutOperator *operator;
    NSMutableDictionary *savedDefaults;
}
@end

@implementation PastePalOperatorTests

- (void)setUp
{
    [super setUp];

    // 快照并清空测试相关偏好，保证测试结果不受本机真实历史影响
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    savedDefaults = [[NSMutableDictionary alloc] init];
    for (NSString *key in PastePalTestDefaultKeys()) {
        id value = [defaults objectForKey:key];
        if (value != nil) {
            [savedDefaults setObject:value forKey:key];
        }
        [defaults removeObjectForKey:key];
    }
    [defaults setInteger:10 forKey:@"rememberNum"];
    [defaults setInteger:10 forKey:@"favoritesRememberNum"];
    [defaults setInteger:0 forKey:@"savePreference"];
    [defaults setBool:NO forKey:@"removeDuplicates"];
    [defaults setBool:NO forKey:@"pasteMovesToTop"];
    [defaults setInteger:5000000 forKey:@"imageHistoryMaxBytes"];
    [defaults setInteger:5000000 forKey:@"imageMaxItemBytes"];
    [defaults setBool:YES forKey:@"stifleRememberResizeWarning"];

    tempDirectory = [[NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"PastePalOperatorTests-%@", [[NSUUID UUID] UUIDString]]] retain];
    imageStore = [[PastePalImageStore alloc] initWithRootDirectory:tempDirectory];

    operator = [[FlycutOperator alloc] init];
    // 先注入临时图片目录，避免 initializeStores 创建真实的 Application Support 目录
    [operator setImageStore:imageStore];
    [operator awakeFromNibDisplaying:10 withDisplayLength:40 withSaveSelector:NULL forTarget:nil];
}

- (void)tearDown
{
    [operator release];
    operator = nil;
    [imageStore release];
    imageStore = nil;
    [[NSFileManager defaultManager] removeItemAtPath:tempDirectory error:NULL];
    [tempDirectory release];
    tempDirectory = nil;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in PastePalTestDefaultKeys()) {
        [defaults removeObjectForKey:key];
        id value = [savedDefaults objectForKey:key];
        if (value != nil) {
            [defaults setObject:value forKey:key];
        }
    }
    [defaults synchronize];
    [savedDefaults release];
    savedDefaults = nil;

    [super tearDown];
}

- (void)addText:(NSString *)text
{
    BOOL added = [operator addClipping:text
                                ofType:@"NSStringPboardType"
                               fromApp:@"Tests"
                     withAppBundleURL:nil
                                target:nil
                 clippingAddedSelector:NULL];
    XCTAssertTrue(added);
}

- (BOOL)addImageData:(NSData *)data
{
    int width = 0;
    int height = 0;
    XCTAssertTrue([PastePalImageStore pixelSizeForImageData:data width:&width height:&height]);
    return [operator addImageClippingWithData:data
                                         hash:[PastePalImageStore sha256HexForData:data]
                                          uti:@"public.png"
                                   pixelWidth:width
                                  pixelHeight:height
                                     byteSize:(NSInteger)[data length]
                                displayString:nil
                                      fromApp:@"Tests"
                            withAppBundleURL:nil
                                       target:nil
                        clippingAddedSelector:NULL];
}

- (void)testDuplicateImageMovesToTopWithoutGrowingHistory
{
    NSData *red = PastePalTestPNGData(8, 8, 1.0, 0.0, 0.0);
    NSData *blue = PastePalTestPNGData(8, 8, 0.0, 0.0, 1.0);
    XCTAssertTrue([self addImageData:red]);
    XCTAssertTrue([self addImageData:blue]);
    XCTAssertEqual([operator jcListCount], 2);

    // 再次复制红色图片：应移动到栈顶而不是新增条目
    XCTAssertTrue([self addImageData:red]);
    XCTAssertEqual([operator jcListCount], 2);
    XCTAssertEqualObjects([[operator clippingAtStackPosition] imageHash],
                          [PastePalImageStore sha256HexForData:red]);
}

- (void)testUnifiedWindowEvictsOldestAndDeletesImageFile
{
    [operator setRememberNum:3 forPrimaryStore:YES];
    [self addText:@"text one"];

    NSData *red = PastePalTestPNGData(12, 12, 1.0, 0.0, 0.0);
    XCTAssertTrue([self addImageData:red]);
    NSString *redFile = [[[operator clippingAtStackPosition] imageFile] retain];
    XCTAssertTrue([imageStore fileExistsForImageFile:redFile]);

    [self addText:@"text two"];
    NSData *blue = PastePalTestPNGData(12, 12, 0.0, 0.0, 1.0);
    XCTAssertTrue([self addImageData:blue]);
    XCTAssertEqual([operator jcListCount], 3);
    // 只淘汰了最旧的文本，红色图片仍在
    XCTAssertTrue([imageStore fileExistsForImageFile:redFile]);

    // 再插入文本会淘汰红色图片，统一窗口应同时清扫其文件
    [self addText:@"text three"];
    XCTAssertEqual([operator jcListCount], 3);
    XCTAssertFalse([imageStore fileExistsForImageFile:redFile]);

    NSArray *clippings = [operator previousClippings:10 containing:nil];
    XCTAssertEqualObjects([[clippings objectAtIndex:0] contents], @"text three");
    XCTAssertTrue([[clippings objectAtIndex:1] isImage]);
    XCTAssertEqualObjects([[clippings objectAtIndex:2] contents], @"text two");

    [redFile release];
}

- (void)testCapacityEvictsOldestImageOnly
{
    // 大图先进入历史，再设置容量上限，让随后的小图触发淘汰
    NSData *big = PastePalTestPNGData(200, 200, 1.0, 0.0, 0.0);
    NSData *small = PastePalTestPNGData(1, 1, 0.0, 0.0, 1.0);
    XCTAssertTrue([self addImageData:big]);
    NSString *bigFile = [[[operator clippingAtStackPosition] imageFile] retain];

    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)[big length] forKey:@"imageHistoryMaxBytes"];
    XCTAssertTrue([self addImageData:small]);

    XCTAssertEqual([operator jcListCount], 1);
    XCTAssertEqualObjects([[operator clippingAtStackPosition] imageHash],
                          [PastePalImageStore sha256HexForData:small]);
    // 被容量淘汰的最旧图片文件应立即删除
    XCTAssertFalse([imageStore fileExistsForImageFile:bigFile]);

    [bigFile release];
}

- (void)testOversizedImageIsRejectedBeforeWriting
{
    [[NSUserDefaults standardUserDefaults] setInteger:100 forKey:@"imageMaxItemBytes"];
    NSData *data = PastePalTestPNGData(100, 100, 0.5, 0.5, 0.5);
    XCTAssertGreaterThan((NSInteger)[data length], 100);

    XCTAssertFalse([self addImageData:data]);
    XCTAssertEqual([operator jcListCount], 0);
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tempDirectory error:NULL];
    XCTAssertEqual([files count], 0);
}

- (void)testFavoriteImageFileSurvivesHistoryClear
{
    NSData *red = PastePalTestPNGData(6, 6, 1.0, 0.0, 0.0);
    XCTAssertTrue([self addImageData:red]);
    NSString *file = [[[operator clippingAtStackPosition] imageFile] retain];

    // 图片移入收藏后历史被清空，文件仍应保留
    XCTAssertTrue([operator saveFromStackToFavorites]);
    XCTAssertTrue([imageStore fileExistsForImageFile:file]);
    [operator clearList];
    XCTAssertTrue([imageStore fileExistsForImageFile:file]);

    // 收藏也被清空后，文件才允许删除
    [operator toggleToFromFavoritesStore];
    XCTAssertTrue([operator favoritesStoreIsSelected]);
    XCTAssertEqual([operator jcListCount], 1);
    [operator clearList];
    XCTAssertFalse([imageStore fileExistsForImageFile:file]);
    [operator toggleToFromFavoritesStore];

    [file release];
}

- (void)testImageMetadataRoundTripsAndMissingFileIsSkipped
{
    NSData *red = PastePalTestPNGData(9, 4, 1.0, 0.0, 0.0);
    XCTAssertTrue([self addImageData:red]);
    NSString *file = [[[operator clippingAtStackPosition] imageFile] retain];
    NSString *hash = [[[operator clippingAtStackPosition] imageHash] retain];
    [operator saveEngine];

    // 第二个实例从同一份 defaults 和图片目录恢复
    [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"savePreference"];
    FlycutOperator *restored = [[FlycutOperator alloc] init];
    [restored setImageStore:imageStore];
    [restored awakeFromNibDisplaying:10 withDisplayLength:40 withSaveSelector:NULL forTarget:nil];
    XCTAssertEqual([restored jcListCount], 1);
    FlycutClipping *loaded = [restored clippingAtStackPosition];
    XCTAssertTrue([loaded isImage]);
    XCTAssertEqualObjects([loaded imageHash], hash);
    XCTAssertEqualObjects([loaded imageFile], file);
    XCTAssertEqual([loaded imagePixelWidth], 9);
    XCTAssertEqual([loaded imagePixelHeight], 4);
    [restored release];

    // 文件缺失时加载应跳过坏条目而不是崩溃
    [[NSFileManager defaultManager] removeItemAtPath:[imageStore pathForImageFile:file] error:NULL];
    FlycutOperator *missing = [[FlycutOperator alloc] init];
    [missing setImageStore:imageStore];
    [missing awakeFromNibDisplaying:10 withDisplayLength:40 withSaveSelector:NULL forTarget:nil];
    XCTAssertEqual([missing jcListCount], 0);
    [missing release];

    [file release];
    [hash release];
}

@end
