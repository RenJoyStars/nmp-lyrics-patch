//  main.m
//  libNMPLyrics —— 注入 Neural Mix Pro 的「课堂大屏歌词」
//
//  设计目标（用户原话）：实时给学生看歌词 → 窗口可全屏、字号可调、投影清晰。
//
//  歌词来源（优先级）：
//    ① 进程内钩住 open/fopen —— NMP 一读歌就记录真实文件路径，
//       直接从那个文件抠 ID3 USLT 内嵌歌词（用户确认他的歌全带内嵌歌词）。
//    ② 本机快速查找（~/Music 等常见位置，限时）。
//    ③ 用户指定文件夹扫描（限时）。
//    ④ 手动：把 .lrc / .mp3 拖进窗口。
//
//  播放位置：进程内自读无障碍树的 'Elapsed time'（每秒刷新），
//  秒跳变锁相 + 本地时钟内插，±50ms 级，驱动逐词高亮。

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <stdarg.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>

// ================================================================ 诊断日志
// 同时写 NSLog 和 ~/Library/Logs/NMPLyrics.log。
// 补丁在别人机器上不生效时，让对方把这个文件发回来，就能看出断在哪一步：
// 是 dylib 没加载、还是没收到启动通知、还是标题栏没找到。
// 日志只追加、不加密，内容只有启动流程，不含任何用户数据。

static void NMPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[NMPLyrics] %@", msg);
    @try {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"NMPLyrics.log"];
        NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                          [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterShortStyle
                                                         timeStyle:NSDateFormatterMediumStyle],
                          msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {
        // 写不了文件不影响功能
    }
}

// ================================================================ fishhook（精简版）
// 源自 Meta 的 fishhook（BSD 3-Clause），只保留 rebind_symbols_image 能力。

struct rebinding_entry {
    const char *name;
    void *replacement;
    void **replaced;
    struct rebinding_entry *next;
};

static struct rebinding_entry *g_rebindings = NULL;

static void perform_rebinding_with_section(struct rebinding_entry *rebindings,
                                           struct section_64 *section,
                                           intptr_t slide,
                                           struct nlist_64 *symtab, uint32_t nsyms,
                                           char *strtab, uint32_t strsize,
                                           uint32_t *indirect_symtab, uint32_t nindirect) {
    if (section->reserved1 >= nindirect) return;
    uint32_t count = (uint32_t)(section->size / sizeof(void *));
    if (section->reserved1 + count > nindirect) count = nindirect - section->reserved1;
    uint32_t *indirect = indirect_symtab + section->reserved1;
    void **bindings = (void **)((uintptr_t)slide + section->addr);
    for (uint i = 0; i < count; i++) {
        uint32_t symtab_index = indirect[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        // 边界校验：chained fixups 的镜像里这些值可能是垃圾，不校验就 Bus error
        if (symtab_index >= nsyms) continue;
        uint32_t strtab_index = symtab[symtab_index].n_un.n_strx;
        if (strtab_index == 0 || strtab_index >= strsize) continue;
        char *symbol_name = strtab + strtab_index;
        if (symbol_name[0] != '_') continue;
        struct rebinding_entry *cur = rebindings;
        while (cur) {
            if (strcmp(symbol_name + 1, cur->name) == 0) {
                if (cur->replaced != NULL) *cur->replaced = bindings[i];
                bindings[i] = cur->replacement;
                goto next;
            }
            cur = cur->next;
        }
    next:;
    }
}

static void rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
    if (!g_rebindings) return;
    Dl_info info;
    if (dladdr(header, &info) == 0 || !info.dli_fname) return;
    // 只动 Neural Mix Pro 自己的主二进制：
    // 系统框架用的是 chained fixups，符号指针布局不同，碰了就崩（见崩溃报告）。
    // 我们要抓的 open/fopen 全部来自主二进制里的 minimp3 解码器。
    if (strstr(info.dli_fname, "Neural Mix Pro") == NULL) return;

    struct segment_command_64 *cur_seg_cmd;
    struct segment_command_64 *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;
    bool has_chained_fixups = false;
    uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (struct segment_command_64 *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_64) {
            if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) linkedit_segment = cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == 0x80000034) {   // LC_DYLD_CHAINED_FIXUPS
            has_chained_fixups = true;
        }
    }
    if (has_chained_fixups) return;   // 新式二进制：老方法不适用，静默跳过
    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment) return;
    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    struct nlist_64 *symtab = (struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);
    cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (struct segment_command_64 *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_64) {
            if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
                strcmp(cur_seg_cmd->segname, "__DATA_CONST") != 0) continue;
            struct section_64 *sections = (struct section_64 *)(cur + sizeof(struct segment_command_64));
            for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
                struct section_64 *sect = &sections[j];
                if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS ||
                    (sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
                    perform_rebinding_with_section(g_rebindings, sect, slide, symtab,
                                                   symtab_cmd->nsyms, strtab, symtab_cmd->strsize,
                                                   indirect_symtab, dysymtab_cmd->nindirectsyms);
                }
            }
        }
    }
}

static void rebind_symbols(void) {
    _dyld_register_func_for_add_image(rebind_symbols_for_image);
}

// ================================================================ 文件捕获钩子

static int (*orig_open)(const char *, int, ...);
static int (*orig_openat)(int, const char *, int, ...);
static FILE *(*orig_fopen)(const char *, const char *);

static NSString *LastAudioPath = nil;   // 最近打开的音频文件（主线程读写）

static BOOL LooksLikeAudio(const char *path) {
    if (!path) return NO;
    size_t n = strlen(path);
    if (n < 5) return NO;
    NSString *p = [NSString stringWithUTF8String:path];
    NSString *ext = p.pathExtension.lowercaseString;
    return [@[@"mp3", @"m4a", @"flac", @"wav", @"aac", @"aiff"] containsObject:ext];
}

static void RecordPath(const char *path) {
    if (!LooksLikeAudio(path)) return;
    NSString *p = [NSString stringWithUTF8String:path];
    if (!p) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        LastAudioPath = p;
    });
}

static int hooked_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    RecordPath(path);
    return orig_open(path, flags, mode);
}

static int hooked_openat(int fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    RecordPath(path);
    return orig_openat(fd, path, flags, mode);
}

static FILE *hooked_fopen(const char *path, const char *mode) {
    RecordPath(path);
    return orig_fopen(path, mode);
}

// ================================================================ 偏好键

static NSString *const kPrefFolder     = @"cn.renqiaoyi.lyrics.folder";
static NSString *const kPrefOnTop      = @"cn.renqiaoyi.lyrics.onTop";
static NSString *const kPrefFontScale  = @"cn.renqiaoyi.lyrics.fontScale";
static NSString *const kPrefFontSizePx = @"cn.renqiaoyi.lyrics.fontSizePx";
static NSString *const kPrefFontWeight = @"cn.renqiaoyi.lyrics.fontWeight";
static NSString *const kPrefAlignment  = @"cn.renqiaoyi.lyrics.alignment";
static NSString *const kPrefAmbientBg  = @"cn.renqiaoyi.lyrics.ambientBg";
static NSString *const kDefaultFolder =
    @"~/Library/Mobile Documents/com~apple~CloudDocs/音乐";

// ================================================================ 歌词模型

@interface NMPWord : NSObject
@property (nonatomic, assign) double time;
@property (nonatomic, copy)   NSString *text;
+ (instancetype)wordWithTime:(double)t;
@end
@implementation NMPWord
+ (instancetype)wordWithTime:(double)t {
    NMPWord *w = [[NMPWord alloc] init];
    w.time = t; w.text = @"";
    return w;
}
@end

@interface NMPLine : NSObject
@property (nonatomic, assign) double time;
/// 这一行的「实际演唱时长」——不含它后面的间奏。
/// 旧代码直接拿「下一行的时间差」当扫光时长，只要中间有间奏，
/// 这行就被摊成 10 秒慢慢扫，用户看到的就是「慢动作」。
@property (nonatomic, assign) double duration;
@property (nonatomic, copy)   NSString *text;
@property (nonatomic, strong) NSArray<NMPWord *> *words;
/// 歌词源里**真有**逐字时间戳（不是后面合成的）。
/// 只有这种行，才知道「最后一个字什么时候唱完」，间奏才有可能判准；
/// Apple Music / SimpMusic 也是只对逐字歌词画三个点，纯行级 LRC 一律不画。
@property (nonatomic, assign) BOOL timed;
@end
@implementation NMPLine
@end

// ================================================================ 工具

static double ParseClock(NSString *s) {
    if (s.length == 0) return -1;
    // 容忍 Unicode 减号 −、空格、以及 "-04:06" 前缀等杂讯
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= '0' && c <= '9') || c == ':' || c == '.') {
            [clean appendFormat:@"%C", c];
        }
    }
    NSArray *parts = [clean componentsSeparatedByString:@":"];
    // 三种格式都要吃：
    //   mm:ss        （最常见）
    //   hh:mm:ss     （少数平台导出，例如 [00:00:12]）
    //   ss           （极少）
    double total = 0;
    if (parts.count == 3) {
        total = [parts[0] doubleValue] * 3600 + [parts[1] doubleValue] * 60
              + [parts[2] doubleValue];
    } else if (parts.count == 2) {
        double m = [parts[0] doubleValue], sec = [parts[1] doubleValue];
        if (sec >= 60) return -1;
        total = m * 60 + sec;
    } else {
        return -1;
    }
    return total;   // ⚠️ 这行曾经被误删：没有它返回值是未定义的，
                    // 实测会把所有行时间都变成 0 → 二分查找永远命中最后一句（歌词卡住）
}

static NSString *NormalizeTitle(NSString *s) {
    NSMutableCharacterSet *drop = [NSMutableCharacterSet
        characterSetWithCharactersInString:@" ‐-—·・·!！?？.。,，()（）[]【】\"'‘’“”&+×"];
    NSArray *parts = [s componentsSeparatedByCharactersInSet:drop];
    return [[parts componentsJoinedByString:@""] lowercaseString];
}

// ================================================================ 封面主色提取（Apple Music 流光背景）

static NSArray<NSColor *> *NMPDefaultAmbientPalette(void) {
    return @[
        [NSColor colorWithSRGBRed:0.14 green:0.16 blue:0.34 alpha:1.0],
        [NSColor colorWithSRGBRed:0.26 green:0.13 blue:0.36 alpha:1.0],
        [NSColor colorWithSRGBRed:0.09 green:0.24 blue:0.34 alpha:1.0],
        [NSColor colorWithSRGBRed:0.18 green:0.11 blue:0.26 alpha:1.0]
    ];
}

static NSColor *NMPTuneAmbientColor(CGFloat r, CGFloat g, CGFloat b) {
    NSColor *c = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
    CGFloat h = 0, s = 0, v = 0, a = 1;
    [c getHue:&h saturation:&s brightness:&v alpha:&a];
    // 提饱和、压亮度，保证流光浓郁同时不抢白色歌词对比度
    s = MIN(0.86, MAX(0.32, s * 1.38));
    v = MIN(0.50, MAX(0.20, v * 0.78 + 0.10));
    return [NSColor colorWithHue:h saturation:s brightness:v alpha:1.0];
}

static NSArray<NSColor *> *NMPExtractPaletteFromImage(NSImage *img) {
    if (!img) return NMPDefaultAmbientPalette();
    NSRect r = NSMakeRect(0, 0, 16, 16);
    CGImageRef cg = [img CGImageForProposedRect:&r context:nil hints:nil];
    if (!cg) return NMPDefaultAmbientPalette();
    uint8_t px[16 * 16 * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 16, 16, 8, 16 * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NMPDefaultAmbientPalette();
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 16, 16), cg);
    CGContextRelease(ctx);

    // 四个象限分别取均值主色，天然形成封面四角对应的流光层次
    NSMutableArray<NSColor *> *out = [NSMutableArray arrayWithCapacity:4];
    int qx[4] = {0, 8, 0, 8};
    int qy[4] = {0, 0, 8, 8};
    for (int q = 0; q < 4; q++) {
        double sr = 0, sg = 0, sb = 0, cnt = 0;
        for (int y = qy[q]; y < qy[q] + 8; y++) {
            for (int x = qx[q]; x < qx[q] + 8; x++) {
                int off = (y * 16 + x) * 4;
                if (px[off + 3] < 20) continue;
                sr += px[off] / 255.0;
                sg += px[off + 1] / 255.0;
                sb += px[off + 2] / 255.0;
                cnt += 1.0;
            }
        }
        if (cnt > 0) {
            [out addObject:NMPTuneAmbientColor(sr / cnt, sg / cnt, sb / cnt)];
        } else {
            [out addObject:NMPDefaultAmbientPalette()[q]];
        }
    }
    return out;
}

static NSColor *NMPLerpColor(NSColor *a, NSColor *b, CGFloat t) {
    if (!a) return b;
    if (!b || t <= 0.001) return a;
    if (t >= 0.999) return b;
    NSColor *ca = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: a;
    NSColor *cb = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: b;
    CGFloat r1 = 0, g1 = 0, b1 = 0, a1 = 1;
    CGFloat r2 = 0, g2 = 0, b2 = 0, a2 = 1;
    [ca getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [cb getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    return [NSColor colorWithSRGBRed:r1 + (r2 - r1) * t
                               green:g1 + (g2 - g1) * t
                                blue:b1 + (b2 - b1) * t
                               alpha:1.0];
}

// ================================================================ 歌词舞台视图（Apple Music 风格升级版）

@interface NMPStageView : NSView
@property (nonatomic, strong) NSArray<NMPLine *> *lines;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, assign) NSInteger activeWord;
@property (nonatomic, assign) BOOL beforeStart;
@property (nonatomic, assign) CGFloat activeProgress;
@property (nonatomic, readonly) CGFloat fontSize;
@property (nonatomic, assign) CGFloat fontSizePx;
@property (nonatomic, assign) NSInteger fontWeightIndex; // 0:常规, 1:中黑, 2:粗体, 3:特粗
@property (nonatomic, assign) NSInteger alignmentIndex;  // 0:居中, 1:靠左
@property (nonatomic, assign) BOOL ambientBg;            // YES: Apple Music 流光背景 / NO: 教室纯黑
@property (nonatomic, strong) NSImage *artwork;
@property (nonatomic, copy)   NSString *trackTitle;
@property (nonatomic, copy)   NSString *trackArtist;
@property (nonatomic, assign) BOOL animating;
@property (nonatomic, assign) BOOL showDots;
@property (nonatomic, assign) double dotPhase;
@property (nonatomic, assign) CGFloat dotFade;
@property (nonatomic, assign) BOOL forceSettle;
@property (nonatomic, weak) NSView *hoverBar;
@property (nonatomic, strong) NSColor *bgColor;
@property (nonatomic, copy) void (^onSeekToSeconds)(double seconds);
@end

@implementation NMPStageView {
    NSMutableDictionary<NSNumber *, NSNumber *> *_textH;
    CGFloat _cacheFS;
    CGFloat _cacheW;
    CGFloat _scrollY;
    CGFloat _scrollVelocity;
    // 屏幕坐标下的每行视觉槽位（用于精准命中点击/悬停）
    NSArray<NSNumber *> *_screenLineTops;
    NSArray<NSNumber *> *_screenLineHeights;
    // Apple Music 逐行独立非线性弹簧（每行独立位置、速度、延迟，产生拖尾波浪滚动）
    NSMutableArray<NSNumber *> *_linePosY;
    NSMutableArray<NSNumber *> *_lineVelY;
    NSMutableArray<NSNumber *> *_lineDelay;
    BOOL _lineStatesInitialized;
    // 间奏三点独立平滑跟随位置
    CGFloat _dotsScreenY;
    BOOL _dotsPosValid;

    // 高斯景深 + 动态模糊纹理缓存（CoreImage GPU 加速，每行只渲染一次）
    CIContext *_ciCtx;
    NSMutableDictionary<NSString *, NSImage *> *_blurCache;

    NSGradient *_gTop;
    NSGradient *_gBot;
    CGFloat _gHeight;
    BOOL _gAmbient;
    NSInteger _activeIndex;
    NSInteger _prevActiveIndex;
    CGFloat _transitionProgress;
    NSInteger _fontWeightIndex;
    NSInteger _alignmentIndex;
    BOOL _ambientBg;

    // 真实帧时间 + 流光相位 + 封面配色平滑过渡
    CFTimeInterval _lastFrameTime;
    double _ambientPhase;
    NSArray<NSColor *> *_paletteFrom;
    NSArray<NSColor *> *_paletteTo;
    CGFloat _bgFade;

    // 滚轮自由浏览 & 悬停行高亮 & 悬浮胶囊自动隐藏
    BOOL _manualBrowsing;
    CGFloat _manualScrollOffset;
    CFTimeInterval _lastManualScrollTime;
    NSInteger _hoverLineIndex;
    NSTimer *_hudHideTimer;

    // 活跃行布局缓存（底字与扫光共用同一 LayoutManager，彻底消除错位）
    NSInteger _cachedKaraokeIdx;
    CGFloat _cachedKaraokeFS;
    CGFloat _cachedKaraokeW;
    NSInteger _cachedKaraokeWt;
    NSInteger _cachedKaraokeAl;
    NSTextStorage *_activeTS;
    NSLayoutManager *_activeLM;
    NSTextContainer *_activeTC;
}

@synthesize activeIndex = _activeIndex;
@synthesize ambientBg = _ambientBg;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _prevActiveIndex = -1;
        _transitionProgress = 1.0;
        _hoverLineIndex = -1;
        _cachedKaraokeIdx = -1;
        _ambientBg = YES;
        _paletteFrom = NMPDefaultAmbientPalette();
        _paletteTo = _paletteFrom;
        _bgFade = 1.0;
        _lastFrameTime = CACurrentMediaTime();
        _textH = [NSMutableDictionary dictionary];
        _blurCache = [NSMutableDictionary dictionary];
        _linePosY = [NSMutableArray array];
        _lineVelY = [NSMutableArray array];
        _lineDelay = [NSMutableArray array];
    }
    return self;
}

- (void)invalidateLayoutCaches {
    [_textH removeAllObjects];
    [_blurCache removeAllObjects];
    _cachedKaraokeIdx = -1;
    _activeTS = nil;
    _activeLM = nil;
    _activeTC = nil;
    _lineStatesInitialized = NO;
    _dotsPosValid = NO;
}

- (void)setFontWeightIndex:(NSInteger)idx {
    if (_fontWeightIndex == idx) return;
    _fontWeightIndex = idx;
    [self invalidateLayoutCaches];
    [self setNeedsDisplay:YES];
}

- (void)setAlignmentIndex:(NSInteger)idx {
    if (_alignmentIndex == idx) return;
    _alignmentIndex = idx;
    [self invalidateLayoutCaches];
    [self setNeedsDisplay:YES];
}

- (void)setAmbientBg:(BOOL)ambientBg {
    if (_ambientBg == ambientBg) return;
    _ambientBg = ambientBg;
    _gTop = nil; _gBot = nil;
    [self setNeedsDisplay:YES];
}

- (void)setArtwork:(NSImage *)artwork {
    if (_artwork == artwork) return;
    _artwork = artwork;
    // 采样当前已插值出的配色作为过渡起点，切歌时流光丝滑变色
    NSMutableArray<NSColor *> *cur = [NSMutableArray arrayWithCapacity:4];
    for (int i = 0; i < 4; i++) {
        [cur addObject:NMPLerpColor(_paletteFrom[i], _paletteTo[i], _bgFade)];
    }
    _paletteFrom = cur;
    _paletteTo = NMPExtractPaletteFromImage(artwork);
    _bgFade = 0.0;
    self.animating = YES;
    [self setNeedsDisplay:YES];
}

- (NSFontWeight)activeWeight {
    switch (self.fontWeightIndex) {
        case 0:  return NSFontWeightMedium;
        case 1:  return NSFontWeightSemibold;
        case 2:  return NSFontWeightBold;
        case 3:  return NSFontWeightHeavy;
        default: return NSFontWeightBold;
    }
}

- (NSFontWeight)inactiveWeightForDist:(NSInteger)dist {
    switch (self.fontWeightIndex) {
        case 0:  return (dist <= 1) ? NSFontWeightRegular : NSFontWeightLight;
        case 1:  return (dist <= 1) ? NSFontWeightMedium  : NSFontWeightRegular;
        case 2:  return (dist <= 1) ? NSFontWeightMedium  : NSFontWeightRegular;
        case 3:  return (dist <= 1) ? NSFontWeightBold    : NSFontWeightMedium;
        default: return (dist <= 1) ? NSFontWeightMedium  : NSFontWeightRegular;
    }
}

- (void)setActiveIndex:(NSInteger)newIdx {
    if (_activeIndex == newIdx) return;
    NSInteger oldIdx = _activeIndex;
    BOOL forward = (newIdx >= oldIdx);
    if (_lines.count > 0 && labs(newIdx - oldIdx) == 1) {
        _prevActiveIndex = oldIdx;
        _transitionProgress = 0.0;
    } else {
        _prevActiveIndex = -1;
        _transitionProgress = 1.0;
    }
    _activeIndex = newIdx;

    // Apple Music 标志性逐行阶梯延迟：正常切句 46ms 拖尾；跨多行点击跳转时收紧延迟避免滞后感
    if (_lineStatesInitialized && _lineDelay.count == _lines.count && !_manualBrowsing) {
        BOOL farJump = (labs(newIdx - oldIdx) > 2);
        double stepMain = farJump ? 0.024 : 0.046;
        double capMain  = farJump ? 0.16  : 0.28;
        double stepBack = farJump ? 0.012 : 0.020;
        double capBack  = farJump ? 0.08  : 0.11;
        for (NSInteger i = 0; i < (NSInteger)_lines.count; i++) {
            NSInteger d = labs(i - newIdx);
            double delay = 0.0;
            if (forward) {
                delay = (i >= newIdx) ? MIN(capMain, d * stepMain) : MIN(capBack, d * stepBack);
            } else {
                delay = (i <= newIdx) ? MIN(capMain, d * stepMain) : MIN(capBack, d * stepBack);
            }
            _lineDelay[i] = @(delay);
        }
    }

    self.animating = YES;
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return YES; }

- (void)setLines:(NSArray<NMPLine *> *)lines {
    if (_lines == lines) return;
    _lines = lines;
    [self invalidateLayoutCaches];
    _scrollY = 0;
    _scrollVelocity = 0;
    _manualBrowsing = NO;
    _manualScrollOffset = 0;
    _hoverLineIndex = -1;
    _screenLineTops = nil;
    _screenLineHeights = nil;
    [_linePosY removeAllObjects];
    [_lineVelY removeAllObjects];
    [_lineDelay removeAllObjects];
    _activeIndex = 0;
    _prevActiveIndex = -1;
    _transitionProgress = 1.0;
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self invalidateLayoutCaches];
    [self setNeedsDisplay:YES];
}

- (CGFloat)fontSize {
    CGFloat px = (self.fontSizePx >= 16.0) ? self.fontSizePx : 64.0;
    return MAX(16.0, MIN(260.0, px));
}

- (void)setFontSizePx:(CGFloat)fontSizePx {
    CGFloat clamped = MAX(16.0, MIN(260.0, fontSizePx));
    if (fabs(_fontSizePx - clamped) < 0.1) return;
    _fontSizePx = clamped;
    [self invalidateLayoutCaches];
    [self setNeedsDisplay:YES];
}

// ── 鼠标悬停与自动隐藏 HUD（副屏非激活状态也能呼出，静止 2.2s 自动淡出）──
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    NSTrackingArea *area = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                      NSTrackingActiveAlways | NSTrackingInVisibleRect)
               owner:self userInfo:nil];
    [self addTrackingArea:area];
}

- (void)scheduleHUDAutoHide {
    [_hudHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _hudHideTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 repeats:NO block:^(NSTimer *t) {
        NMPStageView *me = weakSelf;
        if (!me || !me.window) return;
        // 正在输入框里填字号或光标停在控制胶囊上时，不自动隐藏
        if (me.hoverBar) {
            NSResponder *fr = me.window.firstResponder;
            if ([fr isKindOfClass:[NSTextView class]]) {
                NSView *v = (NSView *)fr;
                if ([v isDescendantOf:me.hoverBar]) {
                    [me scheduleHUDAutoHide];
                    return;
                }
            }
            NSPoint screenPt = [NSEvent mouseLocation];
            NSPoint winPt = [me.window convertPointFromScreen:screenPt];
            NSPoint inBar = [me.hoverBar convertPoint:winPt fromView:nil];
            if (NSPointInRect(inBar, NSInsetRect(me.hoverBar.bounds, -6, -6))) {
                [me scheduleHUDAutoHide];
                return;
            }
        }
        [me fadeHoverTo:0.0];
    }];
}

- (void)mouseEntered:(NSEvent *)event {
    [self fadeHoverTo:1.0];
    [self scheduleHUDAutoHide];
}

- (void)mouseExited:(NSEvent *)event {
    [_hudHideTimer invalidate];
    _hudHideTimer = nil;
    [self fadeHoverTo:0.0];
    if (_hoverLineIndex != -1) {
        _hoverLineIndex = -1;
        [[NSCursor arrowCursor] set];
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    [self fadeHoverTo:1.0];
    [self scheduleHUDAutoHide];
    NSPoint locInWin = event.locationInWindow;
    NSPoint pt = [self convertPoint:locInWin fromView:nil];

    BOOL overHUD = NO;
    if (self.hoverBar && self.hoverBar.alphaValue > 0.05) {
        NSPoint inBar = [self.hoverBar convertPoint:locInWin fromView:nil];
        overHUD = NSPointInRect(inBar, self.hoverBar.bounds);
    }
    NSInteger hit = -1;
    if (!overHUD && pt.y > 46 && self.lines.count && _screenLineTops.count) {
        for (NSInteger i = 0; i < (NSInteger)_screenLineTops.count; i++) {
            CGFloat top = [_screenLineTops[i] doubleValue];
            CGFloat h = (i < (NSInteger)_screenLineHeights.count) ? [_screenLineHeights[i] doubleValue] : 40.0;
            if (pt.y >= top - 8.0 && pt.y <= top + h + 8.0) { hit = i; break; }
        }
    }
    if (hit != _hoverLineIndex) {
        _hoverLineIndex = hit;
        if (hit >= 0) [[NSCursor pointingHandCursor] set];
        else [[NSCursor arrowCursor] set];
        [self setNeedsDisplay:YES];
    }
}

- (void)fadeHoverTo:(CGFloat)alpha {
    NSView *bar = self.hoverBar;
    if (!bar) return;
    if (fabs(bar.alphaValue - alpha) < 0.01) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.20;
        [[bar animator] setAlphaValue:alpha];
    } completionHandler:nil];
}

// ── 触控板 / 滚轮自由浏览歌词，静止 2.5s 自动弹回当前句 ──
- (void)scrollWheel:(NSEvent *)event {
    if (!self.lines.count || !_screenLineTops.count) return;
    CGFloat dy = event.scrollingDeltaY;
    if (!event.hasPreciseScrollingDeltas) dy *= 14.0;
    if (fabs(dy) < 0.01) return;
    _manualBrowsing = YES;
    _manualScrollOffset -= dy;
    _lastManualScrollTime = CACurrentMediaTime();
    self.animating = YES;
    [self setNeedsDisplay:YES];
}

// ── 点击歌词行跳转播放（顶部 46pt 保留拖动窗口）──
- (void)mouseDown:(NSEvent *)event {
    NSPoint locInWin = event.locationInWindow;
    NSPoint pt = [self convertPoint:locInWin fromView:nil];

    if (self.hoverBar && self.hoverBar.alphaValue > 0.05) {
        NSPoint inBar = [self.hoverBar convertPoint:locInWin fromView:nil];
        if (NSPointInRect(inBar, self.hoverBar.bounds)) {
            [super mouseDown:event];
            return;
        }
    }
    // 点回歌词区域时提交字号输入框编辑并归还焦点
    if ([self.window.firstResponder isKindOfClass:[NSTextView class]]) {
        [self.window makeFirstResponder:self];
    }
    if (pt.y <= 46) {
        [self.window performWindowDragWithEvent:event];
        return;
    }
    if (!self.lines.count || !_screenLineTops.count) return;

    NSInteger hitIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)_screenLineTops.count; i++) {
        CGFloat top = [_screenLineTops[i] doubleValue];
        CGFloat h = (i < (NSInteger)_screenLineHeights.count) ? [_screenLineHeights[i] doubleValue] : 40.0;
        if (pt.y >= top - 8.0 && pt.y <= top + h + 8.0) { hitIndex = i; break; }
    }

    if (hitIndex >= 0 && hitIndex < (NSInteger)self.lines.count) {
        _manualBrowsing = NO;
        _manualScrollOffset = 0;
        double seekTime = self.lines[hitIndex].time;
        if (seekTime >= 0 && self.onSeekToSeconds) {
            self.onSeekToSeconds(seekTime);
        }
    }
}

- (void)drawAmbientBackgroundInRect:(NSRect)b ctx:(CGContextRef)ctx {
    // 深邃底色
    NSColor *c0 = NMPLerpColor(_paletteFrom[0], _paletteTo[0], _bgFade);
    NSColor *c1 = NMPLerpColor(_paletteFrom[1], _paletteTo[1], _bgFade);
    NSColor *c2 = NMPLerpColor(_paletteFrom[2], _paletteTo[2], _bgFade);
    NSColor *c3 = NMPLerpColor(_paletteFrom[3], _paletteTo[3], _bgFade);

    [[NSColor colorWithSRGBRed:0.055 green:0.058 blue:0.075 alpha:1.0] setFill];
    NSRectFill(b);

    CGFloat w = b.size.width, h = b.size.height;
    CGFloat rad = MAX(w, h) * 0.78;
    double p = _ambientPhase;

    NSColor *cols[4] = {c0, c1, c2, c3};
    CGPoint centers[4] = {
        CGPointMake(w * (0.24 + 0.16 * sin(p * 0.31)),       h * (0.26 + 0.16 * cos(p * 0.27))),
        CGPointMake(w * (0.76 + 0.15 * cos(p * 0.23 + 1.1)), h * (0.30 + 0.15 * sin(p * 0.29 + 0.7))),
        CGPointMake(w * (0.30 + 0.16 * cos(p * 0.25 + 2.3)), h * (0.76 + 0.14 * sin(p * 0.21 + 1.5))),
        CGPointMake(w * (0.74 + 0.14 * sin(p * 0.19 + 3.4)), h * (0.74 + 0.16 * cos(p * 0.24 + 2.1)))
    };

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat locs[2] = {0.0, 1.0};
    for (int i = 0; i < 4; i++) {
        NSColor *sc = [cols[i] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: cols[i];
        CGFloat r = 0, g = 0, bl = 0, a = 1;
        [sc getRed:&r green:&g blue:&bl alpha:&a];
        CGFloat comps[8] = {r, g, bl, 0.72, r, g, bl, 0.0};
        CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
        if (grad) {
            CGContextDrawRadialGradient(ctx, grad, centers[i], 0, centers[i], rad,
                                        kCGGradientDrawsAfterEndLocation);
            CGGradientRelease(grad);
        }
    }
    CGColorSpaceRelease(cs);

    // 轻压暗层：确保白色歌词在任何亮色封面上都保持高对比度
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.24] setFill];
    NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
}

- (void)drawTrackHeaderInRect:(NSRect)b {
    if (!self.trackTitle.length && !self.artwork) return;
    CGFloat x = 80.0;
    CGFloat y = 10.0;
    CGFloat thumb = 32.0;
    CGFloat maxTextW = MAX(80.0, b.size.width - x - 24.0);

    if (self.artwork) {
        NSRect ar = NSMakeRect(x, y, thumb, thumb);
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:ar xRadius:6 yRadius:6] addClip];
        [self.artwork drawInRect:ar fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.95 respectFlipped:YES hints:nil];
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.16] setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(ar, 0.5, 0.5) xRadius:6 yRadius:6];
        border.lineWidth = 1.0;
        [border stroke];
        x += thumb + 10.0;
        maxTextW = MAX(60.0, b.size.width - x - 24.0);
    }

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    if (self.trackTitle.length) {
        NSDictionary *ta = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.84],
            NSParagraphStyleAttributeName: ps};
        CGFloat ty = self.trackArtist.length ? (y + 1.0) : (y + 8.0);
        [self.trackTitle drawInRect:NSMakeRect(x, ty, maxTextW, 17) withAttributes:ta];
    }
    if (self.trackArtist.length) {
        NSDictionary *aa = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.50],
            NSParagraphStyleAttributeName: ps};
        [self.trackArtist drawInRect:NSMakeRect(x, y + 17.0, maxTextW, 15) withAttributes:aa];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

    // 真实帧时间 dt（兼容 60Hz / 120Hz ProMotion 屏幕）
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = (CGFloat)(now - _lastFrameTime);
    _lastFrameTime = now;
    if (dt < 1.0 / 120.0 || dt > 1.0 / 20.0) dt = 1.0 / 60.0;

    if (_bgFade < 1.0) {
        _bgFade = MIN(1.0, _bgFade + dt / 1.15);
    }
    if (_ambientBg) {
        _ambientPhase += dt;
        [self drawAmbientBackgroundInRect:b ctx:ctx];
    } else {
        NSColor *bgColor = self.bgColor ?: [NSColor colorWithCalibratedWhite:0.075 alpha:1];
        [bgColor setFill];
        NSRectFill(b);
    }

    NSArray<NMPLine *> *lines = self.lines;
    if (!lines.count) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:22 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.38]};
        NSString *hint = @"等待歌词…";
        NSSize sz = [hint sizeWithAttributes:attrs];
        [hint drawAtPoint:NSMakePoint((b.size.width - sz.width) / 2,
                                      (b.size.height - sz.height) / 2)
           withAttributes:attrs];
        [self drawTrackHeaderInRect:b];
        self.animating = (_bgFade < 1.0);
        return;
    }

    CGFloat fs = self.fontSize;
    CGFloat padX = MAX(28.0, MIN(64.0, b.size.width * 0.06));
    CGFloat maxWidth = MAX(160, b.size.width - padX * 2.0);
    if (!_textH) _textH = [NSMutableDictionary dictionary];
    if (fabs(fs - _cacheFS) > 0.4 || fabs(maxWidth - _cacheW) > 0.4) {
        [self invalidateLayoutCaches];
        _cacheFS = fs;
        _cacheW = maxWidth;
    }

    NSInteger count = (NSInteger)lines.count;
    NSInteger active = MIN(MAX(0, self.activeIndex), count - 1);
    BOOL started = !self.beforeStart;

    BOOL isLeft = (self.alignmentIndex == 1);
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.alignment = isLeft ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    para.lineBreakMode = NSLineBreakByWordWrapping;
    para.lineSpacing = fs * 0.16;

    // ── 行间平滑过渡（0.40s Cubic Smoothstep，真实 dt 驱动）──
    if (_transitionProgress < 1.0) {
        _transitionProgress = MIN(1.0, _transitionProgress + dt / 0.40);
    }
    CGFloat easeT = 1.0;
    if (_transitionProgress < 1.0) {
        CGFloat p = _transitionProgress;
        easeT = p * p * (3.0 - 2.0 * p);
    }

    // ── 1) 先算每行的视觉缩放、透明度与真实视觉高度，保证单行/双行/间奏三点净间距完全一致 ──
    CGFloat dotK = (self.showDots && started) ? self.dotFade : 0.0;
    CGFloat dotD = MAX(6.0, fs * 0.26);
    CGFloat dotPitch = dotD * 2.25;
    CGFloat dotBlockH = dotD * 1.35;
    CGFloat visualGap = MAX(14.0, fs * 0.56);

    NSMutableArray<NSNumber *> *rawHs = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *scales = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *alphas = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *weights = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *visHs = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *targetTops = [NSMutableArray arrayWithCapacity:count];

    CGFloat cursor = 0.0;
    CGFloat dotsTargetContentY = 0.0;

    for (NSInteger i = 0; i < count; i++) {
        CGFloat weight = 0.0;
        if (i == active) weight = (_prevActiveIndex >= 0) ? easeT : 1.0;
        else if (i == _prevActiveIndex) weight = 1.0 - easeT;

        NSInteger dist = labs(i - active);
        CGFloat baseScale = (dist == 0) ? 1.00 : (dist == 1 ? 0.86 : (dist == 2 ? 0.80 : 0.75));
        CGFloat baseAlpha = (dist == 0) ? 1.00 : (dist == 1 ? 0.48 : (dist == 2 ? 0.28 : 0.16));
        CGFloat lineScale = baseScale + (1.00 - baseScale) * weight;
        CGFloat lineAlpha = baseAlpha + (1.00 - baseAlpha) * weight;
        if (i == _hoverLineIndex && i != active) {
            lineAlpha = MIN(0.90, lineAlpha + 0.30);
        }

        CGFloat textH = [self textHeightAtIndex:i fs:fs width:maxWidth para:para];
        CGFloat visH = textH * lineScale;

        [rawHs addObject:@(textH)];
        [scales addObject:@(lineScale)];
        [alphas addObject:@(lineAlpha)];
        [weights addObject:@(weight)];
        [visHs addObject:@(visH)];
        [targetTops addObject:@(cursor)];

        CGFloat lineBottom = cursor + visH;
        cursor = lineBottom + visualGap;
        if (i == active && dotK > 0.01) {
            // 间奏三点严格居中在「当前句底边」与「下一句顶边」之间，上下净距均等于 visualGap
            CGFloat extra = (dotBlockH + visualGap) * dotK;
            CGFloat nextTop = lineBottom + visualGap + extra;
            dotsTargetContentY = (lineBottom + nextTop) * 0.5;
            cursor = nextTop;
        }
    }
    CGFloat total = MAX(0.0, cursor - visualGap);

    CGFloat focusY = MAX(72.0, b.size.height * 0.43);
    CGFloat activeCenter = [targetTops[active] doubleValue] + [visHs[active] doubleValue] * 0.5;
    CGFloat focusContentY = (dotK > 0.02 && started) ? dotsTargetContentY : activeCenter;
    CGFloat autoCam = focusContentY - focusY;
    CGFloat minCam = -focusY + 52.0;
    CGFloat maxCam = MAX(minCam, total - focusY);
    autoCam = MIN(MAX(minCam, autoCam), maxCam);

    // 滚轮自由浏览 2.5s 后自动平滑弹回当前句
    if (_manualBrowsing && (now - _lastManualScrollTime > 2.5)) {
        _manualBrowsing = NO;
        _manualScrollOffset = 0;
    }
    CGFloat targetCam = autoCam;
    if (_manualBrowsing) {
        targetCam = MIN(MAX(minCam, autoCam + _manualScrollOffset), maxCam);
        _manualScrollOffset = targetCam - autoCam;
    }
    _scrollY = targetCam;

    // ── 2) Apple Music 逐行独立非线性弹簧（含阶梯延迟与动态模糊速度感知）──
    if (!_lineStatesInitialized || (NSInteger)_linePosY.count != count || self.forceSettle) {
        [_linePosY removeAllObjects];
        [_lineVelY removeAllObjects];
        [_lineDelay removeAllObjects];
        for (NSInteger i = 0; i < count; i++) {
            [_linePosY addObject:@([targetTops[i] doubleValue] - targetCam)];
            [_lineVelY addObject:@(0.0)];
            [_lineDelay addObject:@(0.0)];
        }
        _lineStatesInitialized = YES;
        _dotsScreenY = dotsTargetContentY - targetCam;
        _dotsPosValid = YES;
        self.forceSettle = NO;
    }

    BOOL anyMoving = NO;
    NSMutableArray<NSNumber *> *curScreenTops = [NSMutableArray arrayWithCapacity:count];
    for (NSInteger i = 0; i < count; i++) {
        CGFloat targetY = [targetTops[i] doubleValue] - targetCam;
        CGFloat y = [_linePosY[i] doubleValue];
        CGFloat v = [_lineVelY[i] doubleValue];
        double delay = [_lineDelay[i] doubleValue];

        if (_manualBrowsing) {
            delay = 0.0;
            CGFloat nextY = y + (targetY - y) * MIN(1.0, dt * 18.0);
            v = (nextY - y) / MAX(dt, 0.004);
            y = nextY;
        } else {
            if (delay > 0.0) {
                delay = MAX(0.0, delay - dt);
                anyMoving = YES;
            } else {
                // 非线性欠阻尼弹簧：k=195, c=23.5（柔和丝滑起停，不生硬）
                CGFloat diff = targetY - y;
                if (!isfinite(y) || fabs(diff) > 12000.0) {
                    y = targetY; v = 0.0;
                } else {
                    CGFloat accel = 195.0 * diff - 23.5 * v;
                    v += accel * dt;
                    y += v * dt;
                    if (fabs(diff) < 0.12 && fabs(v) < 0.8) {
                        y = targetY; v = 0.0;
                    } else {
                        anyMoving = YES;
                    }
                }
            }
        }
        _linePosY[i] = @(y);
        _lineVelY[i] = @(v);
        _lineDelay[i] = @(delay);
        [curScreenTops addObject:@(y)];
    }

    // 间奏三点随当前句底边平滑跟进
    if (dotK > 0.01) {
        CGFloat targetDotY = dotsTargetContentY - targetCam;
        if (!_dotsPosValid) {
            _dotsScreenY = targetDotY;
            _dotsPosValid = YES;
        } else {
            _dotsScreenY += (targetDotY - _dotsScreenY) * MIN(1.0, dt * 14.0);
            if (fabs(targetDotY - _dotsScreenY) > 0.2) anyMoving = YES;
        }
    } else {
        _dotsPosValid = NO;
    }

    self.animating = (_transitionProgress < 1.0 || _bgFade < 1.0 || _manualBrowsing || anyMoving);
    _screenLineTops = curScreenTops;
    _screenLineHeights = visHs;

    CGFloat x0 = floor((b.size.width - maxWidth) / 2.0);

    // ── 3) 绘制可见歌词行（当前行同 LayoutManager 零错位扫光；非当前行 GPU 景深 + 动态模糊）──
    for (NSInteger i = 0; i < count; i++) {
        CGFloat visTop = [curScreenTops[i] doubleValue];
        CGFloat visH = [visHs[i] doubleValue];
        if (visTop + visH < -60.0 || visTop > b.size.height + 60.0) continue;

        CGFloat textH = [rawHs[i] doubleValue];
        CGFloat lineScale = [scales[i] doubleValue];
        CGFloat lineAlpha = [alphas[i] doubleValue];
        CGFloat weight = [weights[i] doubleValue];
        CGFloat vel = fabs([_lineVelY[i] doubleValue]);
        NSInteger dist = labs(i - active);

        CGFloat liftY = -2.0 * weight;
        CGFloat cy = visTop + visH * 0.5 + liftY;
        CGFloat drawTop = cy - textH * 0.5;

        // 悬停柔光底框提示可点击跳转
        if (i == _hoverLineIndex) {
            NSRect pill = NSMakeRect(x0 - 12.0, visTop - 8.0, maxWidth + 24.0, visH + 16.0);
            [[NSColor colorWithCalibratedWhite:1.0 alpha:0.08] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:12 yRadius:12] fill];
        }

        CGFloat cx = isLeft ? x0 : (b.size.width / 2.0);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, cx, cy);
        CGContextScaleCTM(ctx, lineScale, lineScale);
        CGContextTranslateCTM(ctx, -cx, -cy);

        if (i == active && started) {
            CGFloat dim = (1.0 - 0.45 * dotK) * lineAlpha;
            CGFloat cp = [self charPosForLine:lines[i]];
            [self drawActiveLine:lines[i] lineIndex:i fs:fs para:para width:maxWidth x0:x0 top:drawTop alpha:dim charPos:cp];
        } else {
            // 计算景深模糊档位 + 高速滑动动态模糊（悬停或滚轮浏览时自动变清晰）
            NSInteger blurLevel = 0;
            if (i != _hoverLineIndex && !_manualBrowsing) {
                if (dist == 1) blurLevel = 1;
                else if (dist == 2) blurLevel = 2;
                else if (dist >= 3) blurLevel = 3;
                if (i == _prevActiveIndex && weight > 0.35) blurLevel = 0;
                if (vel > 220.0) blurLevel = MIN(3, blurLevel + 1);
            }
            BOOL brightStyle = (i == _prevActiveIndex && started && weight > 0.01);
            [self drawBlurredLineAtIndex:i text:lines[i].text fs:fs para:para width:maxWidth
                                  height:textH x0:x0 top:drawTop alpha:lineAlpha
                               blurLevel:blurLevel brightStyle:brightStyle dist:dist];
        }

        CGContextRestoreGState(ctx);
    }

    // ── 间奏三个呼吸的点（严格上下等距）──
    if (dotK > 0.02 && started) {
        CGFloat cy = _dotsScreenY;
        CGFloat totalW = dotPitch * 2 + dotD;
        CGFloat cx = isLeft ? (x0 + dotD / 2 + 4) : ((b.size.width - totalW) / 2 + dotD / 2);
        if (cy > -dotD * 2 && cy < b.size.height + dotD * 2) {
            double t = self.dotPhase * 2.0;
            for (int k = 0; k < 3; k++) {
                double w = 0.5 + 0.5 * sin(t - k * 0.9);
                double e = pow(w, 2.2);
                CGFloat a = (0.30 + 0.70 * e) * dotK;
                CGFloat d = dotD * (1.0 + 0.12 * e);
                [[NSColor colorWithCalibratedWhite:1.0 alpha:a] setFill];
                NSRect r = NSMakeRect(cx + k * dotPitch - d / 2, cy - d / 2, d, d);
                [[NSBezierPath bezierPathWithOvalInRect:r] fill];
            }
        }
    }

    // ── 上下柔光边缘渐隐 ──
    CGFloat fade = MIN(135, b.size.height * 0.21);
    if (!_gTop || fabs(fade - _gHeight) > 0.5 || _gAmbient != _ambientBg) {
        NSColor *edge = _ambientBg
            ? [NSColor colorWithSRGBRed:0.04 green:0.04 blue:0.06 alpha:0.62]
            : (self.bgColor ?: [NSColor colorWithCalibratedWhite:0.075 alpha:1]);
        _gTop = [[NSGradient alloc] initWithStartingColor:edge
                                              endingColor:[edge colorWithAlphaComponent:0]];
        _gBot = [[NSGradient alloc] initWithStartingColor:[edge colorWithAlphaComponent:0]
                                              endingColor:edge];
        _gHeight = fade;
        _gAmbient = _ambientBg;
    }
    [_gTop drawInRect:NSMakeRect(0, 0, b.size.width, fade) angle:90];
    [_gBot drawInRect:NSMakeRect(0, b.size.height - fade, b.size.width, fade) angle:90];

    // ── 顶部左上角 Apple Music 微曲目信息 ──
    [self drawTrackHeaderInRect:b];
}

/// 用 NSLayoutManager 精确量取行高（lineFragmentPadding=0），与实际绘制高度 1:1 一致，杜绝双行间距偏差
- (CGFloat)textHeightAtIndex:(NSInteger)i fs:(CGFloat)fs
                       width:(CGFloat)maxWidth para:(NSParagraphStyle *)para {
    NSNumber *key = @(i);
    NSNumber *hit = _textH[key];
    if (hit) return hit.doubleValue;
    NSFont *f = [NSFont systemFontOfSize:fs weight:[self activeWeight]];
    NSAttributedString *probe = [[NSAttributedString alloc]
        initWithString:self.lines[i].text
            attributes:@{NSFontAttributeName: f,
                         NSParagraphStyleAttributeName: para,
                         NSKernAttributeName: @(-0.4)}];
    NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:probe];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)];
    tc.lineFragmentPadding = 0;
    [tc setMaximumNumberOfLines:0];
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    [lm ensureLayoutForTextContainer:tc];
    CGFloat h = [lm usedRectForTextContainer:tc].size.height;
    h = MAX(h, fs * 1.15);
    _textH[key] = @(h);
    return h;
}

/// 非当前行渲染：blurLevel 0 直接 LayoutManager 清晰绘制；1–3 走 CoreImage 高斯景深/动态模糊并按行缓存
- (void)drawBlurredLineAtIndex:(NSInteger)idx text:(NSString *)text fs:(CGFloat)fs
                          para:(NSParagraphStyle *)para width:(CGFloat)maxWidth
                        height:(CGFloat)textH x0:(CGFloat)x0 top:(CGFloat)top
                         alpha:(CGFloat)alpha blurLevel:(NSInteger)blurLevel
                   brightStyle:(BOOL)brightStyle dist:(NSInteger)dist {
    if (!text.length || alpha <= 0.01) return;
    NSFontWeight wt = brightStyle ? [self activeWeight] : [self inactiveWeightForDist:dist];

    if (blurLevel <= 0) {
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:fs weight:wt],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:alpha],
            NSParagraphStyleAttributeName: para,
            NSKernAttributeName: @(-0.4)}];
        NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:as];
        NSLayoutManager *lm = [[NSLayoutManager alloc] init];
        NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)];
        tc.lineFragmentPadding = 0;
        [tc setMaximumNumberOfLines:0];
        [lm addTextContainer:tc];
        [ts addLayoutManager:lm];
        [lm ensureLayoutForTextContainer:tc];
        NSUInteger total = [lm numberOfGlyphs];
        if (total > 0) [lm drawGlyphsForGlyphRange:NSMakeRange(0, total) atPoint:NSMakePoint(x0, top)];
        return;
    }

    NSString *ck = [NSString stringWithFormat:@"%ld_%ld_%d", (long)idx, (long)blurLevel, (int)brightStyle];
    NSImage *cached = _blurCache[ck];
    CGFloat pad = 16.0;
    if (!cached) {
        if (_blurCache.count > 80) [_blurCache removeAllObjects];
        CGFloat scale = (self.window.backingScaleFactor > 1.0) ? self.window.backingScaleFactor : 2.0;
        CGFloat imgW = ceil(maxWidth + pad * 2.0);
        CGFloat imgH = ceil(textH + pad * 2.0);
        NSInteger pxW = MAX(2, (NSInteger)ceil(imgW * scale));
        NSInteger pxH = MAX(2, (NSInteger)ceil(imgH * scale));

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:pxW pixelsHigh:pxH
                       bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                      colorSpaceName:NSCalibratedRGBColorSpace
                         bytesPerRow:0 bitsPerPixel:0];
        rep.size = NSMakeSize(imgW, imgH);

        NSGraphicsContext *bctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        CGContextRef cgCtx = bctx.CGContext;
        CGContextSaveGState(cgCtx);
        // 翻转 CTM 为左上角原点，并显式告知 NSGraphicsContext flipped:YES，
        // 否则 NSLayoutManager 会按未翻转坐标系再倒置一次导致字形上下颠倒
        CGContextTranslateCTM(cgCtx, 0, imgH);
        CGContextScaleCTM(cgCtx, 1.0, -1.0);
        NSGraphicsContext *flippedCtx = [NSGraphicsContext graphicsContextWithCGContext:cgCtx flipped:YES];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:flippedCtx];

        NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:fs weight:wt],
            NSForegroundColorAttributeName: [NSColor whiteColor],
            NSParagraphStyleAttributeName: para,
            NSKernAttributeName: @(-0.4)}];
        NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:as];
        NSLayoutManager *lm = [[NSLayoutManager alloc] init];
        NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)];
        tc.lineFragmentPadding = 0;
        [tc setMaximumNumberOfLines:0];
        [lm addTextContainer:tc];
        [ts addLayoutManager:lm];
        [lm ensureLayoutForTextContainer:tc];
        NSUInteger total = [lm numberOfGlyphs];
        if (total > 0) [lm drawGlyphsForGlyphRange:NSMakeRange(0, total) atPoint:NSMakePoint(pad, pad)];
        [NSGraphicsContext restoreGraphicsState];
        CGContextRestoreGState(cgCtx);

        CGFloat radii[4] = {0.0, 1.5, 2.7, 4.0};
        CGFloat r = radii[MIN(3, MAX(1, blurLevel))] * scale;
        CIImage *ciIn = [[CIImage alloc] initWithBitmapImageRep:rep];
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blur setValue:ciIn forKey:kCIInputImageKey];
        [blur setValue:@(r) forKey:kCIInputRadiusKey];
        CIImage *ciOut = blur.outputImage;
        if (ciOut) {
            if (!_ciCtx) _ciCtx = [CIContext contextWithOptions:nil];
            CGImageRef cgOut = [_ciCtx createCGImage:ciOut fromRect:CGRectMake(0, 0, pxW, pxH)];
            if (cgOut) {
                cached = [[NSImage alloc] initWithCGImage:cgOut size:NSMakeSize(imgW, imgH)];
                CGImageRelease(cgOut);
            }
        }
        if (cached) _blurCache[ck] = cached;
    }
    if (cached) {
        [cached drawInRect:NSMakeRect(x0 - pad, top - pad, maxWidth + pad * 2.0, textH + pad * 2.0)
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:alpha
            respectFlipped:YES
                     hints:nil];
    }
}

- (NSAttributedString *)currentLine:(NMPLine *)line fs:(CGFloat)fs
                               para:(NSParagraphStyle *)para bright:(BOOL)bright {
    return [self currentLine:line fs:fs para:para bright:bright alpha:1.0];
}

- (NSAttributedString *)currentLine:(NMPLine *)line fs:(CGFloat)fs
                               para:(NSParagraphStyle *)para bright:(BOOL)bright
                              alpha:(CGFloat)alpha {
    NSColor *color = bright ? [NSColor colorWithCalibratedWhite:1.0 alpha:alpha]
                            : [NSColor colorWithCalibratedWhite:1.0 alpha:0.30 * alpha];
    return [[NSAttributedString alloc] initWithString:line.text attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:fs weight:[self activeWeight]],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: para,
        NSKernAttributeName: @(-0.4)}];
}

- (CGFloat)charPosForLine:(NMPLine *)line {
    CGFloat p = MIN(1, MAX(0, self.activeProgress));
    if (!line.words.count) return line.text.length * p;
    NSInteger k = self.activeWord;
    if (k < 0 || k >= (NSInteger)line.words.count) return 0;
    NSUInteger base = 0;
    for (NSInteger i = 0; i < k; i++) base += line.words[i].text.length;
    NSUInteger wl = line.words[k].text.length;
    return base + wl * p;
}

/// 当前行统一定位绘制：底色层与羽化高光层共用同一个 NSLayoutManager 和原点，零像素偏移。
- (void)drawActiveLine:(NMPLine *)line lineIndex:(NSInteger)lineIndex
                    fs:(CGFloat)fs para:(NSParagraphStyle *)para
                 width:(CGFloat)maxWidth x0:(CGFloat)x0 top:(CGFloat)top
                 alpha:(CGFloat)alpha charPos:(CGFloat)charPos {
    if (!line.text.length) return;

    BOOL cacheHit = (_activeLM && _cachedKaraokeIdx == lineIndex &&
                     fabs(_cachedKaraokeFS - fs) < 0.2 &&
                     fabs(_cachedKaraokeW - maxWidth) < 0.2 &&
                     _cachedKaraokeWt == _fontWeightIndex &&
                     _cachedKaraokeAl == _alignmentIndex);
    if (!cacheHit) {
        NSAttributedString *base = [self currentLine:line fs:fs para:para bright:NO alpha:alpha];
        _activeTS = [[NSTextStorage alloc] initWithAttributedString:base];
        _activeLM = [[NSLayoutManager alloc] init];
        _activeTC = [[NSTextContainer alloc] initWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)];
        _activeTC.lineFragmentPadding = 0;
        [_activeTC setMaximumNumberOfLines:0];
        [_activeLM addTextContainer:_activeTC];
        [_activeTS addLayoutManager:_activeLM];
        [_activeLM ensureLayoutForTextContainer:_activeTC];
        _cachedKaraokeIdx = lineIndex;
        _cachedKaraokeFS = fs;
        _cachedKaraokeW = maxWidth;
        _cachedKaraokeWt = _fontWeightIndex;
        _cachedKaraokeAl = _alignmentIndex;
    }

    NSLayoutManager *lm = _activeLM;
    NSTextContainer *tc = _activeTC;
    NSUInteger len = _activeTS.length;
    NSUInteger total = [lm numberOfGlyphs];
    if (!len || !total) return;

    NSPoint origin = NSMakePoint(x0, top);

    // ① 绘制未唱暗底层（同 LayoutManager + 同原点）
    NSColor *dimCol = [NSColor colorWithCalibratedWhite:1.0 alpha:0.30 * alpha];
    [_activeTS beginEditing];
    [_activeTS addAttribute:NSForegroundColorAttributeName value:dimCol range:NSMakeRange(0, len)];
    [_activeTS endEditing];
    [lm drawGlyphsForGlyphRange:NSMakeRange(0, total) atPoint:origin];

    if (charPos <= 0.02) return;

    // ② 切亮白色，用完全相同的 LayoutManager + 同原点绘制羽化高光层
    NSColor *brightCol = [NSColor colorWithCalibratedWhite:1.0 alpha:alpha];
    [_activeTS beginEditing];
    [_activeTS addAttribute:NSForegroundColorAttributeName value:brightCol range:NSMakeRange(0, len)];
    [_activeTS endEditing];

    CGFloat cp = MIN(MAX(0, charPos), (CGFloat)len);
    NSUInteger ci = MIN((NSUInteger)floor(cp), len - 1);
    CGFloat frac = (cp >= (CGFloat)len) ? 1.0 : (cp - floor(cp));
    NSUInteger gi = [lm glyphIndexForCharacterAtIndex:ci];
    NSRect gRect = [lm boundingRectForGlyphRange:NSMakeRange(gi, 1) inTextContainer:tc];
    CGFloat sweepX = gRect.origin.x + gRect.size.width * frac;
    CGFloat feather = MIN(26.0, MAX(12.0, fs * 0.34));

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGColorRef glowCol = CGColorCreateGenericRGB(1.0, 1.0, 1.0, 0.34);

    NSUInteger g = 0;
    while (g < total) {
        NSRange lr;
        NSRect fr = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:&lr];
        CGFloat left = fr.origin.x, right = fr.origin.x + fr.size.width;
        if (NSMaxRange(lr) <= gi) {
            CGContextSaveGState(ctx);
            CGContextSetShadowWithColor(ctx, CGSizeZero, fs * 0.12, glowCol);
            [lm drawGlyphsForGlyphRange:lr atPoint:origin];
            CGContextRestoreGState(ctx);
        } else if (lr.location <= gi && gi < NSMaxRange(lr)) {
            CGFloat endX = MIN(right + feather, MAX(left, sweepX));
            if (endX > left + 0.5) {
                CGRect layerRect = CGRectMake(x0 + left - 12.0, fr.origin.y + top - 10.0,
                                              (right - left) + 24.0, fr.size.height + 20.0);
                CGContextSaveGState(ctx);
                CGContextBeginTransparencyLayerWithRect(ctx, layerRect, NULL);
                CGContextSetShadowWithColor(ctx, CGSizeZero, fs * 0.12, glowCol);
                [lm drawGlyphsForGlyphRange:lr atPoint:origin];
                CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);

                CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
                CGFloat fadeEnd = x0 + sweepX + feather * 0.35;
                CGFloat fadeStart = fadeEnd - feather;
                CGFloat comps[8] = {1, 1, 1, 1, 1, 1, 1, 0};
                CGFloat locs[2] = {0.0, 1.0};
                CGGradientRef maskGrad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
                if (maskGrad) {
                    CGContextDrawLinearGradient(ctx, maskGrad,
                                                CGPointMake(fadeStart, 0),
                                                CGPointMake(fadeEnd, 0),
                                                kCGGradientDrawsBeforeStartLocation);
                    CGGradientRelease(maskGrad);
                }
                CGContextEndTransparencyLayer(ctx);
                CGContextRestoreGState(ctx);
            }
        } else {
            break;
        }
        g = NSMaxRange(lr);
    }
    CGColorRelease(glowCol);
    CGColorSpaceRelease(cs);
}

@end

// ================================================================ 拖放转发协议

// ================================================================ 控制器

@interface NMPVerticallyCenteredTextFieldCell : NSTextFieldCell
@end
@implementation NMPVerticallyCenteredTextFieldCell
- (NSRect)drawingRectForBounds:(NSRect)rect {
    NSRect r = [super drawingRectForBounds:rect];
    NSSize sz = [self cellSizeForBounds:rect];
    CGFloat dy = floor((r.size.height - sz.height) * 0.5);
    if (dy > 0) { r.origin.y += dy; r.size.height -= dy; }
    return r;
}
- (void)editWithFrame:(NSRect)rect inView:(NSView *)controlView editor:(NSText *)textObj delegate:(id)delegate event:(NSEvent *)event {
    [super editWithFrame:[self drawingRectForBounds:rect] inView:controlView editor:textObj delegate:delegate event:event];
}
- (void)selectWithFrame:(NSRect)rect inView:(NSView *)controlView editor:(NSText *)textObj delegate:(id)delegate start:(NSInteger)selStart length:(NSInteger)selLength {
    [super selectWithFrame:[self drawingRectForBounds:rect] inView:controlView editor:textObj delegate:delegate start:selStart length:selLength];
}
@end

@interface NMPLyricsController : NSObject <NSWindowDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) NSWindow *lyricsWindow;   // 独立歌词窗（不吸附任何窗口）
@property (nonatomic, strong) NMPStageView *stage;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *renderTimer;
@property (nonatomic, strong) NSTextField *fontSizeField;
@property (nonatomic, strong) NSTextField *fontSizeUnitLabel;
@property (nonatomic, strong) NSVisualEffectView *hudBar;
@property (nonatomic, strong) NSTextField *hudScaleTitle;
@property (nonatomic, strong) NSTextField *hudWeightTitle;
@property (nonatomic, strong) NSSegmentedControl *hudWeightSeg;
@property (nonatomic, strong) NSTextField *hudAlignTitle;
@property (nonatomic, strong) NSSegmentedControl *hudAlignSeg;
@property (nonatomic, strong) NSSegmentedControl *hudTopSeg;
@property (nonatomic, strong) NSSegmentedControl *hudAmbientSeg;
@property (nonatomic, strong) NSBox *hudSep1;
@property (nonatomic, strong) NSBox *hudSep2;
@property (nonatomic, strong) NSBox *hudSep3;
@property (nonatomic, strong) NSBox *hudSep4;
@property (nonatomic, assign) NSUInteger resolveGeneration;
@property (nonatomic, assign) CFTimeInterval lastAmbientTick;

@property (nonatomic, copy)   NSString *trackTitle;
@property (nonatomic, copy)   NSString *trackArtist;
@property (nonatomic, assign) double totalDuration;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL lastElapsedChanged;

@property (nonatomic, assign) double lockedSeconds;
@property (nonatomic, strong) NSDate *lockedDate;
@property (nonatomic, copy)   NSString *lastElapsed;
@property (nonatomic, assign) double lastLockedE;
@property (nonatomic, strong) NSDate *lastAdvanceDate;   // 时间文本最后一次变化的时刻

@property (nonatomic, strong) NSArray<NMPLine *> *lines;
@property (nonatomic, assign) NSInteger lastLineIndex;
@property (nonatomic, assign) double offset;
@property (nonatomic, copy)   NSString *boundTitle;
@property (nonatomic, assign) BOOL matching;
@property (nonatomic, assign) BOOL toggling;
@property (nonatomic, assign) BOOL haveAnchor;
@property (nonatomic, weak) NSButton *lyricsButton;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, strong) NSArray<NMPLine *> *pendingLines;
@property (nonatomic, assign) double pendingOffset;
@property (nonatomic, assign) double lrcOffset;
@property (nonatomic, assign) double cadence;   // 本曲「每字唱多久」的估计，间奏门槛按它缩放

@property (nonatomic) AXUIElementRef appElement;
@property (nonatomic, strong) dispatch_queue_t axQueue;   // AX 兜底专用后台队列
@property (nonatomic, assign) NSInteger viewFailStreak;   // 视图直读连续失手次数
@property (nonatomic, copy)   NSString *axTitle;          // 后台 AX 捎回的曲名（低频）
@property (nonatomic, copy)   NSString *axArtist;
@property (nonatomic, copy)   NSString *axPlay;
@property (nonatomic, assign) NSInteger axPollTick;       // AX 取曲名的节流计数
@end

// 标题栏里那个「歌词」按钮：默认 NSButton 即可，没有额外行为
@interface NMPTitleButton : NSButton
@end
@implementation NMPTitleButton
@end

@implementation NMPLyricsController

+ (instancetype)shared {
    static NMPLyricsController *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        _offset = 0;   // 偏移功能已取消，恒为 0
        _appElement = AXUIElementCreateApplication(getpid());
        // 默认 6 秒：NMP 在分析新歌时一次 AX 查询可能挂很久，页面就跟着冻住。
        // 压到 1 秒，读不到就等下一轮，宁可少一帧数据也不要卡 UI。
        // 注意：现在 AX 已挪到后台队列，这个超时只影响兜底路径的响应速度。
        AXUIElementSetMessagingTimeout(_appElement, 1.0);

        // AX 兜底专用串行队列：低优先级，绝不和界面抢
        _axQueue = dispatch_queue_create("com.renjoy.nmp.axfallback",
                                         dispatch_queue_attr_make_with_qos_class(
                                             DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        [self buildWindow];
        [self observeMenus];
        [self installLyricsHotkey];
        // 窗口改尺寸时立刻重排按钮，不等下一轮 poll —— 拖动改宽时就不会「延迟回位」
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(hostWindowGeometryChanged:)
                                                     name:NSWindowDidResizeNotification
                                                   object:nil];
        
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
                                                    selector:@selector(poll) userInfo:nil repeats:YES];
        // 60fps（扫光要顺），但 render 里会判断「真的有变化」才重绘
        _renderTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self
                                             selector:@selector(render) userInfo:nil repeats:YES];
        _renderTimer.tolerance = 0.004;
        [[NSRunLoop mainRunLoop] addTimer:_renderTimer forMode:NSRunLoopCommonModes];

        // 调试：启动时自动弹出歌词窗，方便截图核对样式
        BOOL wantShow = (getenv("NMP_SHOW_LYRICS") != NULL) ||
                        [[NSUserDefaults standardUserDefaults] boolForKey:@"NMPAutoShowLyrics"];
        for (NSString *a in [NSProcessInfo processInfo].arguments) {
            if ([a isEqualToString:@"--show-lyrics"]) wantShow = YES;
        }
        if (wantShow) {
            NMPLog(@"auto-open lyrics window (args=%@)", [NSProcessInfo processInfo].arguments);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self toggleWindow:nil];
                // 调试：NMP_PREVIEW_DOTS=1 时灌一份假歌词停在间奏上，方便截图核对
                if (getenv("NMP_PREVIEW_DOTS") ||
                    [[NSUserDefaults standardUserDefaults] boolForKey:@"NMPPreviewDots"]) {
                    [_renderTimer invalidate];
                    _renderTimer = nil;
                    [self startDotsPreview];
                }
            });
        }
    }
    return self;
}

// ---------------------------------------------------------------- 窗口

// 调试用：灌一份假歌词，把画面停在「第四句刚唱完、进间奏」的一刻，
// 用来截图核对三个点的大小和焦点位置。只在 NMP_PREVIEW_DOTS=1 时调用。
- (void)startDotsPreview {
    NSArray<NSString *> *texts = @[@"夜色渐浓风声也轻", @"我听见远处传来回音",
                                   @"谁的影子落在窗棂", @"唱完这句就进间奏了",
                                   @"间奏结束又开始唱", @"时间继续往前走"];
    NSMutableArray<NMPLine *> *demo = [NSMutableArray array];
    for (NSUInteger i = 0; i < texts.count; i++) {
        NMPLine *l = [NMPLine new];
        l.time = i * 4.0;
        l.text = texts[i];
        l.duration = 3.4;
        l.timed = YES;
        [demo addObject:l];
    }
    _stage.lines = demo;
    _stage.activeIndex = 3;
    _stage.activeWord = -1;
    _stage.activeProgress = 1.0;
    _stage.beforeStart = NO;
    _stage.showDots = YES;
    _stage.dotFade = 1.0;
    _stage.dotPhase = 1.05;      // 停在一个点最亮的位置
    _stage.animating = NO;
    // 渲染循环已经停了，滚动不会自己收敛；等窗口布局定下来再强制落位，
    // 否则截出来的是「焦点还没走到点上」的中间状态。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.stage.forceSettle = YES;
        [self.stage display];
    });
}

- (void)buildWindow {
    NSColor *bgBlack = [NSColor colorWithSRGBRed:19/255.0 green:21/255.0
                                               blue:22/255.0 alpha:1.0];

    // 无边界沉浸式窗口：流光背景直通红绿灯下方，与 Apple Music macOS 歌词窗一致
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1000, 580)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                          | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                          | NSWindowStyleMaskFullSizeContentView)
                    backing:NSBackingStoreBuffered defer:NO];
    win.releasedWhenClosed = NO;
    win.title = @"歌词";
    win.delegate = self;
    win.minSize = NSMakeSize(360, 240);
    win.backgroundColor = bgBlack;
    win.titlebarAppearsTransparent = YES;
    win.titleVisibility = NSWindowTitleHidden;
    if (@available(macOS 11.0, *)) {
        win.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    }
    [win setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    win.contentView.wantsLayer = YES;
    win.contentView.layer.backgroundColor = bgBlack.CGColor;

    NMPStageView *stage = [[NMPStageView alloc] initWithFrame:win.contentView.bounds];
    stage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    stage.bgColor = bgBlack;
    __weak typeof(self) weakSelf = self;
    stage.onSeekToSeconds = ^(double sec) {
        [weakSelf seekToSeconds:sec];
    };
    [win.contentView addSubview:stage];
    _stage = stage;

    // ── 读取偏好 ──
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat savedPx = [ud doubleForKey:kPrefFontSizePx];
    if (savedPx < 16.0 || savedPx > 260.0) savedPx = 64.0;

    NSInteger savedWeight = [ud integerForKey:kPrefFontWeight];
    if (savedWeight < 0 || savedWeight > 3) savedWeight = 2;

    NSInteger savedAlign = [ud integerForKey:kPrefAlignment];
    if (savedAlign < 0 || savedAlign > 1) savedAlign = 0;

    BOOL savedOnTop = [ud boolForKey:kPrefOnTop];
    if (savedOnTop) win.level = NSFloatingWindowLevel;

    BOOL savedAmbient = ([ud objectForKey:kPrefAmbientBg] == nil) ? YES : [ud boolForKey:kPrefAmbientBg];

    // ── 原生毛玻璃悬浮控制胶囊（宽窗单排 / 窄窗双排自适应，字号直接填 px）──
    NSVisualEffectView *bar = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 14, 560, 38)];
    bar.material = NSVisualEffectMaterialHUDWindow;
    bar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    bar.state = NSVisualEffectStateActive;
    bar.wantsLayer = YES;
    bar.layer.cornerRadius = 19.0;
    bar.layer.borderWidth = 1.0;
    bar.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.18].CGColor;
    bar.layer.masksToBounds = YES;
    bar.alphaValue = 0.0;
    [win.contentView addSubview:bar];
    _hudBar = bar;

    _hudScaleTitle = [self makeHUDLabel:@"字号" frame:NSZeroRect];
    [bar addSubview:_hudScaleTitle];

    NSTextField *pxField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    pxField.cell = [[NMPVerticallyCenteredTextFieldCell alloc] initTextCell:@""];
    pxField.editable = YES;
    pxField.selectable = YES;
    pxField.bezeled = NO;
    pxField.bordered = NO;
    pxField.drawsBackground = YES;
    pxField.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.12];
    pxField.textColor = [NSColor whiteColor];
    pxField.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    pxField.alignment = NSTextAlignmentCenter;
    pxField.focusRingType = NSFocusRingTypeNone;
    pxField.wantsLayer = YES;
    pxField.layer.cornerRadius = 6.0;
    pxField.layer.borderWidth = 1.0;
    pxField.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.22].CGColor;
    pxField.stringValue = [NSString stringWithFormat:@"%.0f", savedPx];
    pxField.toolTip = @"输入字号（16–260 px），回车生效";
    pxField.target = self;
    pxField.action = @selector(fontSizeFieldCommitted:);
    pxField.delegate = self;
    [bar addSubview:pxField];
    _fontSizeField = pxField;

    _fontSizeUnitLabel = [self makeHUDLabel:@"px" frame:NSZeroRect];
    [bar addSubview:_fontSizeUnitLabel];

    _hudSep1 = [self makeHUDSeparatorAtX:0];
    [bar addSubview:_hudSep1];

    _hudWeightTitle = [self makeHUDLabel:@"字重" frame:NSZeroRect];
    [bar addSubview:_hudWeightTitle];

    _hudWeightSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"常规", @"中黑", @"粗体", @"特粗"]
                                                      trackingMode:NSSegmentSwitchTrackingSelectOne
                                                            target:self
                                                            action:@selector(fontWeightChanged:)];
    _hudWeightSeg.controlSize = NSControlSizeSmall;
    _hudWeightSeg.selectedSegment = savedWeight;
    [bar addSubview:_hudWeightSeg];

    _hudSep2 = [self makeHUDSeparatorAtX:0];
    [bar addSubview:_hudSep2];

    _hudAlignTitle = [self makeHUDLabel:@"排版" frame:NSZeroRect];
    [bar addSubview:_hudAlignTitle];

    _hudAlignSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"居中", @"靠左"]
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne
                                                           target:self
                                                           action:@selector(alignmentChanged:)];
    _hudAlignSeg.controlSize = NSControlSizeSmall;
    _hudAlignSeg.selectedSegment = savedAlign;
    [bar addSubview:_hudAlignSeg];

    _hudSep3 = [self makeHUDSeparatorAtX:0];
    [bar addSubview:_hudSep3];

    _hudAmbientSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"流光"]
                                                       trackingMode:NSSegmentSwitchTrackingSelectAny
                                                             target:self
                                                             action:@selector(ambientBgToggled:)];
    _hudAmbientSeg.controlSize = NSControlSizeSmall;
    [_hudAmbientSeg setSelected:savedAmbient forSegment:0];
    [bar addSubview:_hudAmbientSeg];

    _hudSep4 = [self makeHUDSeparatorAtX:0];
    [bar addSubview:_hudSep4];

    _hudTopSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"置顶"]
                                                   trackingMode:NSSegmentSwitchTrackingSelectAny
                                                         target:self
                                                         action:@selector(onTopToggled:)];
    _hudTopSeg.controlSize = NSControlSizeSmall;
    [_hudTopSeg setSelected:savedOnTop forSegment:0];
    [bar addSubview:_hudTopSeg];

    stage.hoverBar = bar;
    stage.fontSizePx = savedPx;
    stage.fontWeightIndex = savedWeight;
    stage.alignmentIndex = savedAlign;
    stage.ambientBg = savedAmbient;

    [win center];
    _lyricsWindow = win;
    [self layoutStage];
}

- (NSTextField *)makeHUDLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *tf = [[NSTextField alloc] initWithFrame:frame];
    tf.editable = NO;
    tf.bordered = NO;
    tf.drawsBackground = NO;
    tf.selectable = NO;
    tf.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    tf.textColor = [NSColor colorWithCalibratedWhite:0.74 alpha:1.0];
    tf.stringValue = text;
    return tf;
}

- (NSTextField *)makeHUDValueLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *tf = [[NSTextField alloc] initWithFrame:frame];
    tf.editable = NO;
    tf.bordered = NO;
    tf.drawsBackground = NO;
    tf.selectable = NO;
    tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    tf.textColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
    tf.alignment = NSTextAlignmentRight;
    tf.stringValue = text;
    return tf;
}

- (NSBox *)makeHUDSeparatorAtX:(CGFloat)x {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(x, 10, 1, 18)];
    box.boxType = NSBoxCustom;
    box.borderType = NSNoBorder;
    box.fillColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.18];
    return box;
}

- (void)layoutStage {
    if (!_stage || !_lyricsWindow) return;
    NSView *cv = _lyricsWindow.contentView;
    if (!cv) return;
    NSRect r = cv.bounds;
    if (!NSEqualRects(_stage.frame, r)) _stage.frame = r;

    if (!_hudBar) return;
    BOOL compact = (r.size.width < 590.0);
    if (!compact) {
        CGFloat barW = 556.0, barH = 38.0;
        _hudBar.frame = NSMakeRect(floor((r.size.width - barW) / 2.0), 14.0, barW, barH);
        _hudBar.layer.cornerRadius = 19.0;

        _hudScaleTitle.frame     = NSMakeRect(14, 11, 26, 16);
        _fontSizeField.frame     = NSMakeRect(42, 8, 46, 22);
        _fontSizeUnitLabel.frame = NSMakeRect(91, 11, 18, 16);
        _hudSep1.hidden = NO; _hudSep1.frame = NSMakeRect(114, 10, 1, 18);

        _hudWeightTitle.frame = NSMakeRect(124, 11, 26, 16);
        _hudWeightSeg.frame   = NSMakeRect(152, 8, 144, 22);
        _hudSep2.hidden = NO; _hudSep2.frame = NSMakeRect(304, 10, 1, 18);

        _hudAlignTitle.frame = NSMakeRect(314, 11, 26, 16);
        _hudAlignSeg.frame   = NSMakeRect(342, 8, 76, 22);
        _hudSep3.hidden = NO; _hudSep3.frame = NSMakeRect(426, 10, 1, 18);

        _hudAmbientSeg.frame = NSMakeRect(435, 8, 48, 22);
        _hudSep4.hidden = NO; _hudSep4.frame = NSMakeRect(491, 10, 1, 18);

        _hudTopSeg.frame     = NSMakeRect(500, 8, 44, 22);
    } else {
        // 窄窗（360–589px）：双排紧凑胶囊，绝不裁切
        CGFloat barW = MIN(328.0, MAX(312.0, r.size.width - 24.0));
        CGFloat barH = 68.0;
        _hudBar.frame = NSMakeRect(floor((r.size.width - barW) / 2.0), 12.0, barW, barH);
        _hudBar.layer.cornerRadius = 14.0;

        // 上排（y=38）：字号 px + 流光 + 置顶
        _hudScaleTitle.frame     = NSMakeRect(14, 41, 26, 16);
        _fontSizeField.frame     = NSMakeRect(42, 38, 52, 22);
        _fontSizeUnitLabel.frame = NSMakeRect(98, 41, 18, 16);
        _hudSep1.hidden = NO; _hudSep1.frame = NSMakeRect(126, 40, 1, 18);
        _hudAmbientSeg.frame = NSMakeRect(138, 38, 62, 22);
        _hudSep4.hidden = NO; _hudSep4.frame = NSMakeRect(210, 40, 1, 18);
        _hudTopSeg.frame     = NSMakeRect(222, 38, 62, 22);

        // 下排（y=8）：字重 + 排版
        _hudWeightTitle.frame = NSMakeRect(12, 11, 26, 16);
        _hudWeightSeg.frame   = NSMakeRect(40, 8, 144, 22);
        _hudSep2.hidden = NO; _hudSep2.frame = NSMakeRect(192, 10, 1, 18);
        _hudAlignTitle.frame  = NSMakeRect(202, 11, 26, 16);
        _hudAlignSeg.frame    = NSMakeRect(230, 8, 78, 22);
        _hudSep3.hidden = YES;
    }
}

- (void)applyFontSizeFromField:(NSTextField *)field {
    NSString *raw = [field.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    double val = raw.doubleValue;
    if (val <= 0) val = _stage.fontSize;
    CGFloat px = MAX(16.0, MIN(260.0, round(val)));
    field.stringValue = [NSString stringWithFormat:@"%.0f", px];
    _stage.fontSizePx = px;
    [[NSUserDefaults standardUserDefaults] setDouble:px forKey:kPrefFontSizePx];
    [_stage setNeedsDisplay:YES];
}

- (void)fontSizeFieldCommitted:(NSTextField *)sender {
    [self applyFontSizeFromField:sender];
    if (_lyricsWindow) [_lyricsWindow makeFirstResponder:_stage];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == _fontSizeField) {
        [self applyFontSizeFromField:_fontSizeField];
    }
}

- (void)fontWeightChanged:(NSSegmentedControl *)sender {
    NSInteger idx = sender.selectedSegment;
    _stage.fontWeightIndex = idx;
    [[NSUserDefaults standardUserDefaults] setInteger:idx forKey:kPrefFontWeight];
    [_stage setNeedsDisplay:YES];
}

- (void)alignmentChanged:(NSSegmentedControl *)sender {
    NSInteger idx = sender.selectedSegment;
    _stage.alignmentIndex = idx;
    [[NSUserDefaults standardUserDefaults] setInteger:idx forKey:kPrefAlignment];
    [_stage setNeedsDisplay:YES];
}

- (void)ambientBgToggled:(NSSegmentedControl *)sender {
    BOOL on = [sender isSelectedForSegment:0];
    _stage.ambientBg = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefAmbientBg];
    [_stage setNeedsDisplay:YES];
}

- (void)onTopToggled:(NSSegmentedControl *)sender {
    BOOL on = [sender isSelectedForSegment:0];
    _lyricsWindow.level = on ? NSFloatingWindowLevel : NSNormalWindowLevel;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefOnTop];
}

// NMP 主窗健康保险：NMP 记得窗口「缩到极小/拖出屏」的状态后就再也不回来，
// 标题栏按钮会挤没。这里做幂等复位（纯独立歌词窗方案下，阁楼绑定已删除）。
// ---------------------------------------------------------------- 界面文字汉化
// 库列表的表头（TRACK / ARTIST / KEY / BPM）和 Export 按钮都是**硬编码英文**：
// 表头连本地化 key 都没有，Export 虽然有个同名 key 但按钮并不走它。
// 只能运行时按「显示出来的文字」精确匹配替换。只碰这些确切的英文词，
// 不做任何模糊匹配，避免误伤歌名/艺人名。
- (NSString *)zhForUIString:(NSString *)text {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // 曲库列表表头
            @"TRACK": @"曲目", @"TITLE": @"标题", @"ARTIST": @"艺人",
            @"ALBUM": @"专辑", @"KEY": @"调性", @"BPM": @"速度",
            @"GENRE": @"风格", @"TIME": @"时长", @"LENGTH": @"时长",
            @"RATING": @"评分", @"PLAYLIST": @"播放列表", @"CRATE": @"歌单",
            // 分轨名（混音台上的四个大字）
            @"VOCALS": @"人声", @"HARMONIC": @"和声",
            @"BASS": @"贝斯", @"DRUMS": @"鼓",
            // 传输/面板
            @"Export": @"导出", @"Export…": @"导出…",
            @"No Tasks": @"暂无任务", @"Export Tasks": @"导出任务",
            @"LIBRARY": @"曲库", @"CRATES": @"歌单", @"SEARCH": @"搜索",
            @"Search": @"搜索", @"Playlist": @"播放列表",
            // 传输栏
            @"PLAY": @"播放", @"PAUSE": @"暂停", @"Play": @"播放", @"Pause": @"暂停",
            @"Beats": @"拍", @"BEATS": @"拍", @"Bars": @"小节", @"BARS": @"小节",
            @"Keys": @"调性", @"Key": @"调性",
            // BPM 弹窗
            @"Edit BPM": @"输入 BPM", @"Reset": @"重置", @"Range ±": @"范围 ±",
            @"Range": @"范围", @"Original": @"原始",
        };
    });
    NSString *t = [text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *hit = map[t];
    if (hit) return hit;

    // 「4 Beats」「2 Bars」：数字 + 单位，单位换成中文
    for (NSArray *pair in @[@[@" Beats", @" 拍"], @[@" Bars", @" 小节"],
                            @[@" Track", @" 轨"], @[@" Tracks", @" 轨"]]) {
        if ([t hasSuffix:pair[0]]) {
            NSString *head = [t substringToIndex:t.length - [pair[0] length]];
            if (head.length && [head rangeOfCharacterFromSet:
                                [NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) {
                return [head stringByAppendingString:pair[1]];
            }
        }
    }
    return nil;
}

- (void)localizeMenuTree:(NSMenu *)m {
    for (NSMenuItem *it in m.itemArray) {
        if (!it.isSeparatorItem) {
            NSString *zh = [self chineseMenuTitle:it.title];
            if (zh && ![zh isEqualToString:it.title]) it.title = zh;
        }
        if (it.submenu) [self localizeMenuTree:it.submenu];
    }
}

- (void)relabelTextFieldsIn:(NSView *)root {
    for (NSView *v in root.subviews) {
        if ([v isKindOfClass:[NSTextField class]]) {
            NSTextField *tf = (NSTextField *)v;
            NSString *zh = [self zhForUIString:tf.stringValue];
            if (zh) {
                NSAttributedString *as = tf.attributedStringValue;
                if (as.length) {
                    NSMutableAttributedString *m = [as mutableCopy];
                    [m replaceCharactersInRange:NSMakeRange(0, m.length) withString:zh];
                    tf.attributedStringValue = m;
                } else {
                    tf.stringValue = zh;
                }
            }
        }
        if (v.menu) {
            // 弹窗菜单不一定属于主菜单树（NSButton 上挂的 NSMenu 就是），单独处理
            for (NSMenuItem *it in v.menu.itemArray) {
                NSString *zh = [self chineseMenuTitle:it.title];
                if (zh && ![zh isEqualToString:it.title]) it.title = zh;
                if (it.submenu) [self localizeMenuTree:it.submenu];
            }
        }
        if ([v isKindOfClass:[NSSegmentedControl class]]) {
            // 分段控件的文字是 segment label，不是 title，必须单独处理
            NSSegmentedControl *sc = (NSSegmentedControl *)v;
            for (NSInteger i = 0; i < sc.segmentCount; i++) {
                NSString *zh = [self zhForUIString:[sc labelForSegment:i]];
                if (zh) [sc setLabel:zh forSegment:i];
            }
        }
        if ([v isKindOfClass:[NSPopUpButton class]]) {
            // NSPopUpButton 是 NSButton 的子类，必须排在前面判断
            NSPopUpButton *pu = (NSPopUpButton *)v;
            for (NSMenuItem *it in pu.menu.itemArray) {
                NSString *zh = [self chineseMenuTitle:it.title];
                if (zh && ![zh isEqualToString:it.title]) it.title = zh;
            }
        } else if ([v isKindOfClass:[NSButton class]]) {
            NSButton *b = (NSButton *)v;
            NSString *zh = [self zhForUIString:b.title];
            if (zh) b.title = zh;
        } else if ([v isKindOfClass:[NSTableView class]]) {
            // 表头是 NSTableColumn.headerCell（旧式 cell），AX 也会读到它的文字
            NSTableView *tv = (NSTableView *)v;
            for (NSTableColumn *col in tv.tableColumns) {
                NSString *zh = [self zhForUIString:col.headerCell.stringValue];
                if (zh) col.headerCell.stringValue = zh;
            }
        }
        [self relabelTextFieldsIn:v];
    }
}

- (void)localizeInterfaceText {
    static BOOL running = NO;
    static NSTimeInterval last = 0;
    static NSInteger lastCount = -1;
    if (running) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSInteger cnt = (NSInteger)[NSApp windows].count;
    BOOL windowAppeared = (cnt != lastCount);
    lastCount = cnt;
    // 新窗口（popover/面板）出现时立刻处理，别等节流；平时限 0.8 秒
    if (!windowAppeared && last && now - last < 0.8) return;
    last = now;
    running = YES;
    for (NSWindow *w in [NSApp windows]) {
        if (w == _lyricsWindow) continue;         // 自己的窗口不碰
        [self relabelTextFieldsIn:w.contentView];
    }
    running = NO;
}

// ---------------------------------------------------------------- 菜单汉化
// 为什么要有这段：主菜单 nib 里一部分条目走本地化 key（填在 Localizable.strings，
// 已经是中文），另一部分是**硬编码英文**（Open / Export Track / Undo …），
// 没有任何 key 可翻，只能运行时改标题。
// 只改「下拉菜单里的条目」，不碰顶部主标题 —— 顶部那排是启动时的快照，
// 实测改 title / attributedTitle / 换菜单对象都不会重绘，白费力气。
- (NSString *)chineseMenuTitle:(NSString *)title {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"Open": @"打开…", @"Export Track": @"导出音轨…",
            @"Export Playlist": @"导出播放列表…", @"Refresh Library": @"刷新曲库",
            @"Undo": @"撤销", @"Redo": @"重做",
            @"Cut": @"剪切", @"Copy": @"拷贝", @"Paste": @"粘贴",
            @"Paste and Match Style": @"粘贴并匹配样式",
            @"Delete": @"删除", @"Select All": @"全选",
            @"Show Library": @"显示曲库", @"Show Waveforms": @"显示波形",
            @"1 Track": @"1 轨", @"2 Tracks": @"2 轨",
            @"3 Tracks": @"3 轨", @"4 Tracks": @"4 轨",
            @"Enter Full Screen": @"进入全屏",
            @"Minimize": @"最小化", @"Minimize All": @"全部最小化",
            @"Close": @"关闭", @"Close All": @"全部关闭",
            @"Zoom": @"缩放", @"Zoom All": @"全部缩放",
            @"Bring All to Front": @"前置全部窗口",
            @"Fill": @"填充", @"Center": @"居中",
            @"User Manual": @"用户手册", @"Support": @"技术支持",
            @"Restore Purchases": @"恢复购买",
            @"About Neural Mix Pro": @"关于 Neural Mix Pro",
            @"Preferences": @"偏好设置", @"Settings": @"设置",
            @"Hide Neural Mix Pro": @"隐藏 Neural Mix Pro",
            @"Hide Others": @"隐藏其他", @"Show All": @"全部显示",
            @"Quit Neural Mix Pro": @"退出 Neural Mix Pro",
            @"Services": @"服务",
        };
    });

    NSString *t = [title stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL dots = NO;
    for (NSString *suf in @[@"…", @"..."]) {
        if ([t hasSuffix:suf]) {
            t = [[t substringToIndex:t.length - suf.length]
                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            dots = YES;
            break;
        }
    }
    NSString *zh = map[t];
    if (!zh) {
        // 分轨名是拼出来的：「Drums 独奏」「静音 Harmonic」
        NSString *r = t;
        for (NSArray *pair in @[@[@"Drums", @"鼓"], @[@"Harmonic", @"和声"],
                                @[@"Vocals", @"人声"], @[@"Bass", @"贝斯"]]) {
            r = [r stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
        }
        if ([r isEqualToString:t]) return nil;
        zh = r;
    }
    if (!dots) return zh;
    if ([zh hasSuffix:@"…"]) return zh;
    return [zh stringByAppendingString:@"…"];
}

- (void)localizeDropdowns {
    static BOOL running = NO;
    if (running) return;     // 改标题会触发菜单通知，挡住自我递归
    running = YES;

    NSMenu *root = [NSApp mainMenu];
    if (!root) { running = NO; return; }

    NSMutableArray<NSMenu *> *stack = [NSMutableArray array];
    for (NSMenuItem *top in root.itemArray) {
        if (top.submenu) [stack addObject:top.submenu];   // 从第一层下拉开始
    }
    while (stack.count) {
        NSMenu *m = stack.lastObject;
        [stack removeLastObject];
        for (NSMenuItem *it in m.itemArray) {
            if (!it.isSeparatorItem) {
                NSString *zh = [self chineseMenuTitle:it.title];
                if (zh && ![zh isEqualToString:it.title]) it.title = zh;
            }
            if (it.submenu) [stack addObject:it.submenu];
        }
    }
    running = NO;
}

// 只在离散事件上补一下：菜单是打开时才绘制的，这几处足够覆盖。
// 「歌词」菜单删了，⌘L 用事件监听留着（只认 ⌘L，不碰别的键）
- (void)installLyricsHotkey {
    static BOOL once = NO;
    if (once) return;
    once = YES;
    __weak NMPLyricsController *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (e.modifierFlags & NSEventModifierFlagCommand &&
            !(e.modifierFlags & NSEventModifierFlagOption)) {
            NSString *ch = e.charactersIgnoringModifiers.lowercaseString;
            if ([ch isEqualToString:@"l"]) {
                NMPLyricsController *me = weakSelf;
                if (me) [me toggleWindow:nil];
                return nil;
            }
        }
        return e;
    }];
}

- (void)observeMenus {
    static BOOL once = NO;
    if (once) return;
    once = YES;
    // ⚠️ 回调里绝对不能用 [NMPLyricsController shared]：
    // 本方法是在 init（dispatch_once 里）被调用的，改标题又会立刻发出菜单通知，
    // 通知回调再进 shared → dispatch_once 重入 → 直接 SIGTRAP（实测崩过）。
    __weak NMPLyricsController *weakSelf = self;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSArray *names = @[NSApplicationDidBecomeActiveNotification,
                       NSWindowDidBecomeKeyNotification,
                       NSWindowDidUpdateNotification,          // 弹窗/popover 出来时补一次
                       NSMenuDidBeginTrackingNotification,
                       NSMenuDidChangeItemNotification,
                       NSMenuDidAddItemNotification];
    for (NSString *name in names) {
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            NMPLyricsController *me = weakSelf;
            if (!me) return;
            // 通知里的 object 就是刚打开/变化的那个 NSMenu —— 弹窗菜单只有这一刻才存在
            if ([n.object isKindOfClass:[NSMenu class]]) {
                [me localizeMenuTree:(NSMenu *)n.object];
            }
            [me localizeDropdowns];
            [me localizeInterfaceText];
        }];
    }
    // 首次汉化放到 init 返回之后，避免在 dispatch_once 内部触发自身
    dispatch_async(dispatch_get_main_queue(), ^{
        NMPLyricsController *me = weakSelf;
        if (me) [me localizeDropdowns];
    });
    // 界面控件是异步建出来的，补两次（1s / 3s）就够，不做轮询
    for (double d = 1.0; d <= 3.05; d += 2.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NMPLyricsController *me = weakSelf;
            if (me) [me localizeInterfaceText];
        });
    }
}

- (NSWindow *)hostWindow {
    NSWindow *fallback = nil;
    CGFloat bestArea = 0;
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible) continue;
        if (w == _lyricsWindow) continue;                       // 别把歌词窗当宿主
        if (!(w.styleMask & NSWindowStyleMaskTitled)) continue;
        NSString *t = w.title ?: @"";
        // 正常路径：NMP 主窗口标题里带 "Neural Mix"
        if ([t containsString:@"Neural Mix"]) return w;
        // 退路：标题被本地化改写、或版本换了标题时，取面积最大的带标题窗口（就是主窗口）。
        // 原来只认 isEqualToString:@"Neural Mix"，标题一变就永远返回 nil
        // —— 按钮不出现、⌘L 也没有，看起来就像"补丁没生效"。
        CGFloat area = w.frame.size.width * w.frame.size.height;
        if (area > bestArea) { bestArea = area; fallback = w; }
    }
    if (fallback) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; NMPLog(@"hostWindow fallback -> \"%@\"", fallback.title); }
    }
    return fallback;
}

- (void)normalizeHostWindow:(NSWindow *)w {
    if (!w) return;
    // 鼠标按住（拖窗口/拉尺寸/点任何东西）时绝不插手 ——
    // 之前每 50ms 复位一次，表现就是「拖动的时候窗口自动弹回原位」。
    if ([NSEvent pressedMouseButtons] != 0) return;
    // 限频：至多 1 秒一次（挂在 50ms 渲染定时器上，不限频等于每秒抢 20 次）
    static NSDate *last;
    NSDate *now = [NSDate date];
    if (last && [now timeIntervalSinceDate:last] < 1.0) return;
    last = now;
    // 用窗口自己所在的屏幕算边界 —— 用 mainScreen 的话，多屏/改过显示缩放
    // 会把别的屏上的窗口误判成 offscreen，然后永远往主屏拽。
    NSScreen *sc = [w screen] ?: NSScreen.mainScreen;
    NSRect vf = sc.visibleFrame;
    NSRect f = w.frame;
    // 只救「几乎整体跑出屏幕」的窗口；窗口多小是用户的自由，不许干预。
    // （174×115 缩在屏幕外的历史案例：NSMaxX=-66 < 40，offscreen 能抓到，不需要尺寸判断）
    BOOL offscreen = (NSMaxX(f) < vf.origin.x + 40) || (f.origin.x > NSMaxX(vf) - 40)
                  || (NSMaxY(f) < vf.origin.y + 40) || (f.origin.y > NSMaxY(vf) - 40);
    if (offscreen) {
        CGFloat nw = MIN(1180, vf.size.width - 80);
        CGFloat nh = MIN(720, vf.size.height - 100);
        NSRect r = NSMakeRect(vf.origin.x + (vf.size.width - nw) / 2,
                              vf.origin.y + (vf.size.height - nh) / 2 + 30, nw, nh);
        [w setFrame:r display:YES];
    }
}


// ---------------------------------------------------------------- 菜单

// ---------------------------------------------------------------- 轮询

- (void)poll {
    if (!_appElement) return;

    NSString *title = @"", *artist = @"", *elapsedText = @"", *remainingText = @"", *playBtnTitle = @"";

    // ── 路径一：同进程视图直读（主线程、零 IPC、微秒级）──
    // 这才是「自己读自己界面」该有的样子：界面就是 NSView 树，直接读 stringValue。
    BOOL got = [self readFromViewsTitle:&title artist:&artist elapsed:&elapsedText
                              remaining:&remainingText playTitle:&playBtnTitle];

    if (!got) {
        // 标签匹配不上：实测 NMP 的 "Elapsed time" 是 AX 层运行时生成的，
        // AppKit 的 accessibilityDescription 是空的。退一步用「时间格式 + 兄弟配对」
        // 认出进度条那两个数字 —— 歌词只需要进度，这一步就够。
        NSString *el = @"", *rem = @"";
        if ([self readTimesFromViewsElapsed:&el remaining:&rem]) {
            elapsedText = el;
            remainingText = rem;
            title = _axTitle ?: @"";
            artist = _axArtist ?: @"";
            playBtnTitle = _axPlay ?: @"";
            got = YES;
        }
    }

    if (got) {
        _viewFailStreak = 0;
        [self applyState:title artist:artist elapsed:elapsedText
               remaining:remainingText play:playBtnTitle];
        // 曲名/演奏状态变化很慢，不必每 0.1 秒都去问一次 —— 1 秒一次足够
        if (++_axPollTick >= 10) { _axPollTick = 0; [self refreshMetaViaAXAsync]; }
    } else {
        // ── 路径二：整轮 AX 兜底，放后台，主线程永不等它 ──
        if (_viewFailStreak < 3 && ++_viewFailStreak == 3) {
            NMPLog(@"视图直读未命中，改用 AX 后台兜底");
            // 排查用：NMP_DUMP_VIEWS=1 启动时把视图树打进日志，
            // 用来确认文字到底在哪种控件里、无障碍标签是什么。
            if (getenv("NMP_DUMP_VIEWS")) [self dumpViews];
        }
        [self pollViaAXAsync];
    }

    // 按钮要先于 title 检查：没歌时也要能呼出歌词窗
    [self ensureHostButton];
    // 主窗健康复位放在 10Hz 的 poll 里做就够了，别占 60fps 的渲染循环
    [self normalizeHostWindow:[self hostWindow]];
}

// AX 兜底：整轮跑在后台串行队列上。主线程只负责在结果回来后更新状态，
// 永远不会再等 XPC —— 这就是「点暂停卡 5 秒」的根治点。
- (void)pollViaAXAsync {
    static BOOL busy = NO;
    if (busy) return;          // 上一轮没回来就别叠加，避免队列堆积
    busy = YES;
    dispatch_async(_axQueue, ^{
        NSString *title = @"", *artist = @"", *elapsedText = @"", *remainingText = @"", *playBtnTitle = @"";
        [self readViaAXTitle:&title artist:&artist elapsed:&elapsedText
                   remaining:&remainingText playTitle:&playBtnTitle];
        dispatch_async(dispatch_get_main_queue(), ^{
            busy = NO;
            if (title.length) { self->_axTitle = title; self->_axArtist = artist; }
            if (playBtnTitle.length) self->_axPlay = playBtnTitle;
            [self applyState:title artist:artist elapsed:elapsedText
                   remaining:remainingText play:playBtnTitle];
        });
    });
}

// 低频刷新曲名/演奏状态：同样在后台队列，不阻塞主线程。
- (void)refreshMetaViaAXAsync {
    static BOOL busy = NO;
    if (busy) return;
    busy = YES;
    dispatch_async(_axQueue, ^{
        NSString *t = @"", *a = @"", *e = @"", *r = @"", *p = @"";
        [self readViaAXTitle:&t artist:&a elapsed:&e remaining:&r playTitle:&p];
        dispatch_async(dispatch_get_main_queue(), ^{
            busy = NO;
            if (t.length) { self->_axTitle = t; self->_axArtist = a; }
            if (p.length) self->_axPlay = p;
        });
    });
}

- (void)readViaAXTitle:(NSString *__autoreleasing *)title
                artist:(NSString *__autoreleasing *)artist
               elapsed:(NSString *__autoreleasing *)elapsed
             remaining:(NSString *__autoreleasing *)remaining
             playTitle:(NSString *__autoreleasing *)playTitle {
    if (!_appElement) return;
    CFTypeRef windowsRef = NULL;
    if (AXUIElementCopyAttributeValue(_appElement, kAXWindowsAttribute, &windowsRef) != kAXErrorSuccess) return;
    CFArrayRef windows = (CFArrayRef)windowsRef;
    NSString *fallbackElapsed = @"", *fallbackRemaining = @"", *fallbackPlay = @"";
    BOOL gotTitle = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        NSString *t = @"", *a2 = @"", *el = @"", *rem = @"", *pb = @"";
        double fr = 0;
        [self walk:win depth:0 title:&t artist:&a2 elapsed:&el
         remaining:&rem playTitle:&pb fraction:&fr];
        // ① 优先采用「有曲名」的窗口，避免两个唱盘的 Elapsed time 互相覆盖导致来回跳
        if (t.length && !gotTitle) {
            *title = t; *artist = a2; *elapsed = el;
            *remaining = rem; *playTitle = pb;
            gotTitle = YES;
        } else if (!gotTitle && !fallbackElapsed.length && el.length) {
            // ② 但万一 AX 暂时读不到曲名（换歌瞬间、标题元素未就绪），
            //    也必须继续用时间推进，否则位置彻底冻结 —— 就是「歌词卡住」。
            fallbackElapsed = el;
            fallbackRemaining = rem;
            fallbackPlay = pb;
        }
    }
    if (!gotTitle && fallbackElapsed.length) {
        *elapsed = fallbackElapsed;
        *remaining = fallbackRemaining;
        *playTitle = fallbackPlay;
    }
    CFRelease(windowsRef);
}

// ---------------------------------------------------------------- 视图直读

// 取一个视图的无障碍标签。NSTextField 在 AX 层暴露的 kAXDescriptionAttribute
// 就是这里的 accessibilityDescription，同进程直接读，不用绕 XPC。
- (NSString *)viewAXLabel:(NSView *)v {
    @try {
        // accessibilityDescription / accessibilityLabel / accessibilityIdentifier
        // 属于 NSAccessibility 协议，NSView 头文件里没有直接声明，走 KVC 拿。
        NSArray *keys = @[@"accessibilityDescription", @"accessibilityLabel", @"accessibilityIdentifier"];
        for (NSString *k in keys) {
            id d = [v valueForKey:k];
            if ([d isKindOfClass:[NSString class]] && [d length]) return d;
        }
        return nil;
    } @catch (NSException *e) {
        return nil;
    }
}

- (void)scanView:(NSView *)v depth:(int)depth
           title:(NSString *__autoreleasing *)title
          artist:(NSString *__autoreleasing *)artist
         elapsed:(NSString *__autoreleasing *)elapsed
       remaining:(NSString *__autoreleasing *)remaining
       playTitle:(NSString *__autoreleasing *)playTitle {
    if (!v || depth > 16) return;
    if (v.hidden) return;

    if ([v isKindOfClass:[NSTextField class]]) {
        NSTextField *tf = (NSTextField *)v;
        NSString *val = tf.stringValue;
        if (val.length) {
            NSString *label = [self viewAXLabel:tf];
            if (label.length) {
                if ([label isEqualToString:@"Title"]) *title = val;
                else if ([label isEqualToString:@"Artist"]) *artist = val;
                else if ([label isEqualToString:@"Elapsed time"]) *elapsed = val;
                else if ([label isEqualToString:@"Remaining time"]) *remaining = val;
            }
        }
    } else if ([v isKindOfClass:[NSButton class]]) {
        NSString *t = ((NSButton *)v).title;
        if (t.length && t.length > (*playTitle).length &&
            ([t containsString:@"Pause"] || [t containsString:@"Play"] ||
             [t containsString:@"暂停"] || [t containsString:@"播放"])) {
            *playTitle = t;
        }
    }

    for (NSView *sub in v.subviews) {
        [self scanView:sub depth:depth + 1 title:title artist:artist
               elapsed:elapsed remaining:remaining playTitle:playTitle];
    }
}

// ---------------------------------------------------------------- 视图树诊断
// 只在 NMP_DUMP_VIEWS=1 时跑一次，用来确认文字落在哪种控件、无障碍标签是什么。
static NSInteger g_dumpLines = 0;

- (void)dumpView:(NSView *)v depth:(int)d {
    if (!v || g_dumpLines > 900) return;
    g_dumpLines++;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(d * 2) withString:@" " startingAtIndex:0];
    NSMutableString *extra = [NSMutableString string];
    @try {
        if ([v isKindOfClass:[NSTextField class]]) {
            NSTextField *tf = (NSTextField *)v;
            if (tf.stringValue.length) {
                [extra appendFormat:@" text=\"%@\"", tf.stringValue];
            }
        } else if ([v isKindOfClass:[NSButton class]]) {
            NSString *t = ((NSButton *)v).title;
            if (t.length) [extra appendFormat:@" title=\"%@\"", t];
        }
        id desc = [v valueForKey:@"accessibilityDescription"];
        if ([desc isKindOfClass:[NSString class]] && [desc length]) {
            [extra appendFormat:@" desc=\"%@\"", desc];
        }
        id ident = [v valueForKey:@"accessibilityIdentifier"];
        if ([ident isKindOfClass:[NSString class]] && [ident length]) {
            [extra appendFormat:@" id=\"%@\"", ident];
        }
    } @catch (NSException *e) { }

    NMPLog(@"%@%@%@", pad, NSStringFromClass([v class]), extra);
    for (NSView *s in v.subviews) [self dumpView:s depth:d + 1];
}

- (void)dumpViews {
    g_dumpLines = 0;
    NMPLog(@"---- 视图树 dump 开始 ----");
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible) continue;
        NMPLog(@"[窗口] \"%@\" %@", w.title, NSStringFromClass([w class]));
        [self dumpView:w.contentView depth:1];
    }
    NMPLog(@"---- dump 结束（%ld 行）----", (long)g_dumpLines);
}

/// 返回 YES 表示「至少读到了一项可信内容」，可以走主路径；/// NO 表示视图里没有我们要的东西，交给 AX 兜底。
- (BOOL)readFromViewsTitle:(NSString *__autoreleasing *)title
                    artist:(NSString *__autoreleasing *)artist
                   elapsed:(NSString *__autoreleasing *)elapsed
                 remaining:(NSString *__autoreleasing *)remaining
                 playTitle:(NSString *__autoreleasing *)playTitle {
    if (![NSThread isMainThread]) return NO;
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible || w == _lyricsWindow) continue;
        NSView *root = w.contentView;
        if (!root) continue;
        [self scanView:root depth:0 title:title artist:artist
               elapsed:elapsed remaining:remaining playTitle:playTitle];
        if ((*title).length) break;   // 认准有曲名的那个窗口（和 AX 路径同一策略）
    }
    return ((*title).length > 0 || (*elapsed).length > 0);
}

// ---------------------------------------------------------------- 进度直读（不靠无障碍标签）

// 是否是 mm:ss / hh:mm:ss 这种时钟文本
static BOOL NMPIsClock(NSString *s) {
    if (s.length < 4 || s.length > 8) return NO;
    NSInteger colons = 0, digits = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ':') colons++;
        else if (c >= '0' && c <= '9') digits++;
        else return NO;
    }
    return colons >= 1 && digits >= 3;
}

- (void)collectTextFields:(NSView *)v into:(NSMutableArray<NSTextField *> *)out depth:(int)d {
    if (!v || d > 16 || out.count > 600) return;
    if ([v isKindOfClass:[NSTextField class]]) [out addObject:(NSTextField *)v];
    for (NSView *s in v.subviews) [self collectTextFields:s into:out depth:d + 1];
}

/// 用「时间文本 + 同父容器成对出现」认出进度：
/// 剩余时间是全界面唯一带负号的时钟（-00:00），它的兄弟节点就是已播时间。
/// 这样不依赖任何无障碍标签 —— 实测 NMP 的标签只在 AX 层运行时生成，
/// AppKit 的 accessibilityDescription 是空的，按标签匹配必然全部落空。
- (BOOL)readTimesFromViewsElapsed:(NSString *__autoreleasing *)elapsed
                        remaining:(NSString *__autoreleasing *)remaining {
    if (![NSThread isMainThread]) return NO;
    for (NSWindow *w in [NSApp windows]) {
        if (!w.isVisible || w == _lyricsWindow) continue;
        NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
        [self collectTextFields:w.contentView into:fields depth:0];
        NSTextField *remField = nil;
        for (NSTextField *tf in fields) {
            NSString *s = tf.stringValue;
            if (s.length > 1 && [s hasPrefix:@"-"] && NMPIsClock([s substringFromIndex:1])) {
                remField = tf;
                break;
            }
        }
        if (!remField) continue;
        *remaining = remField.stringValue;
        // 已播时间排在剩余时间前面，但不一定同一个父容器（可能各裹一层）。
        // 所以在扁平顺序里向前回溯找最近的那个时钟文本。
        NSInteger idx = (NSInteger)[fields indexOfObject:remField];
        for (NSInteger j = idx - 1; j >= 0 && j >= idx - 8; j--) {
            NSString *s = fields[(NSUInteger)j].stringValue;
            if (NMPIsClock(s)) { *elapsed = s; break; }
        }
        static BOOL loggedOnce = NO;
        if (!loggedOnce && getenv("NMP_DUMP_VIEWS")) {
            loggedOnce = YES;
            NMPLog(@"进度直读命中：elapsed=\"%@\" remaining=\"%@\"",
                   (*elapsed).length ? *elapsed : @"(空)",
                   (*remaining).length ? *remaining : @"(空)");
        }
        return YES;
    }
    return NO;
}

// ---------------------------------------------------------------- 状态应用

- (void)applyState:(NSString *)title
            artist:(NSString *)artist
           elapsed:(NSString *)elapsedText
         remaining:(NSString *)remainingText
              play:(NSString *)playBtnTitle {

    // 视图路径只拿得到进度，曲名靠后台 AX 低频捎回。曲名没到之前先沿用上一次的
    // —— 否则每一轮都会被判成「换歌」，歌词被反复清空又重新加载，看起来就是一直闪。
    if (title.length == 0) {
        title = _trackTitle ?: @"";
        if (artist.length == 0) artist = _trackArtist ?: @"";
    }

    if (title.length == 0 && elapsedText.length == 0) return;

    BOOL titleChanged = ![title isEqualToString:_trackTitle];
    BOOL advancing = ![elapsedText isEqualToString:_lastElapsed];
    _lastElapsed = elapsedText;

    _trackTitle = title;
    _trackArtist = artist;

    NSDate *now = [NSDate date];
    if (advancing) _lastAdvanceDate = now;

    // ── 播放状态判定：按钮标题优先，时间推进兜底 ──
    // 注意界面已汉化，按钮标题可能是「播放 / 暂停」（切换钮，含义模糊）；
    // 这时两个关键词都会命中，视为"模糊"，退回时间推进判断。
    // 「时间在推进」是一手证据，永远优先 —— 按钮标题在不同版本里可能表示
    // "当前状态"也可能表示"点击后的动作"，拿它判暂停会把正在播的歌冻住。
    BOOL recentAdvance = _lastAdvanceDate &&
                         -[_lastAdvanceDate timeIntervalSinceNow] < 1.5;
    BOOL saysPause = [playBtnTitle containsString:@"Pause"] || [playBtnTitle containsString:@"暂停"];
    BOOL saysPlay  = [playBtnTitle containsString:@"Play"]  || [playBtnTitle containsString:@"播放"];
    BOOL ambiguous = saysPause && saysPlay;
    BOOL playingNow;
    if (recentAdvance) {
        playingNow = YES;                       // 时间在走 → 一定在播
    } else if (saysPause && !ambiguous) {
        playingNow = YES;                       // 按钮明确显示"暂停中"
    } else {
        playingNow = NO;                        // 1.5 秒没走 → 认为已停
    }

    // 播放→暂停的瞬间：把"当前显示位置"固化下来再冻结。
    // 旧代码直接冻结在 AX 的整秒值上，会往回跳最多 2.5 秒（用户看到的就是鬼畜/倒退）。
    if (_playing && !playingNow) {
        _lockedSeconds = [self currentPosition];
        _lockedDate = now;
    }
    _playing = playingNow;

    double e = ParseClock(elapsedText);
    if (e >= 0) {
        double r = ParseClock(remainingText);
        if (r >= 0) _totalDuration = e + r;

        if (!_haveAnchor) {
            _lockedSeconds = e; _lockedDate = now; _lastLockedE = e; _haveAnchor = YES;
        } else if (fabs(e - _lastLockedE) > 0.01 || fabs(e - _lockedSeconds) > 1.2) {
            // AX 值变了（或用户 seek）：用「只向前纠偏」的方式重锚 ——
            // AX 是整秒（向下取整），本地时钟通常略超前；若照抄会导致每秒往回跳一次。
            double pos = [self currentPosition];
            double diff = e - pos;
            if (fabs(diff) > 1.2) {
                _lockedSeconds = e; _lockedDate = now;      // seek 或严重漂移：直接钉住
            } else if (diff > 0.02) {
                _lockedSeconds = e; _lockedDate = now;      // AX 更靠前：追上去
            }
            // diff 为负（AX 落后于本地）→ 忽略，继续用本地时钟，避免倒退抖动
            _lastLockedE = e;
        }
    }
    if (titleChanged) {
        _resolveGeneration++;
        _lines = nil;
        _lastLineIndex = -2;
        _boundTitle = nil;
        _retryCount = 0;
        _haveAnchor = NO;      // 新歌：重新锚定，别拿上一首的位置算
        _lastLockedE = -1;
        _playing = NO;
        _stage.trackTitle = title;
        _stage.trackArtist = artist;
        _stage.artwork = nil;
        [self resolveLyricsForTitle:title artist:artist];
    }
}

// ---------------------------------------------------------------- 歌词点击跳转播放 (Click to Seek)

- (NSSlider *)findScrubberInView:(NSView *)v {
    if (!v) return nil;
    if ([v isKindOfClass:NSClassFromString(@"NMPlayerScrubberSlider")]) {
        return (NSSlider *)v;
    }
    for (NSView *sub in v.subviews) {
        NSSlider *hit = [self findScrubberInView:sub];
        if (hit) return hit;
    }
    return nil;
}

- (NSSlider *)findFallbackScrubberInView:(NSView *)v {
    if (!v) return nil;
    NSSlider *best = nil;
    if ([v isKindOfClass:[NSSlider class]] && ![[v window] isEqual:_lyricsWindow]) {
        NSSlider *sl = (NSSlider *)v;
        if (sl.frame.size.width > 120) best = sl;
    }
    for (NSView *sub in v.subviews) {
        NSSlider *cand = [self findFallbackScrubberInView:sub];
        if (cand && (!best || cand.frame.size.width > best.frame.size.width)) {
            best = cand;
        }
    }
    return best;
}

- (void)seekToSeconds:(double)seconds {
    if (seconds < 0) seconds = 0;
    if (_totalDuration > 0 && seconds > _totalDuration) seconds = _totalDuration;

    NSWindow *mainWin = [self hostWindow];
    if (mainWin) {
        NSSlider *scrubber = [self findScrubberInView:mainWin.contentView];
        if (!scrubber) scrubber = [self findFallbackScrubberInView:mainWin.contentView];

        if (scrubber) {
            double maxV = scrubber.maxValue;
            double minV = scrubber.minValue;
            double targetVal = 0;
            if (maxV <= 1.05 && _totalDuration > 0) {
                targetVal = seconds / _totalDuration;
            } else {
                targetVal = seconds;
            }
            targetVal = MIN(maxV, MAX(minV, targetVal));
            [scrubber setDoubleValue:targetVal];
            if (scrubber.action) {
                [NSApp sendAction:scrubber.action to:scrubber.target from:scrubber];
            }
        }
    }

    // 立即更新本地锚点，使歌词舞台无缝平滑瞬移，不再因等待 AX 轮询而产生视觉倒退
    _lockedSeconds = seconds;
    _lockedDate = [NSDate date];
    _lastLockedE = seconds;
    _haveAnchor = YES;
    // 点击某行跳转时走非线性弹簧平滑滑过去，不再瞬移
    _stage.forceSettle = NO;
    [self render];
}

// ---------------------------------------------------------------- NMP 标题栏里的「歌词」按钮
// 用 NSTitlebarAccessoryViewController 挂进标题栏右侧 —— 和系统原生按钮同排，
// 不再挤在波形图里和文字串在一起。
// 歌词按钮：直接插进 NMP 标题栏那三个按钮所在的 NSStackView。
// 早先用 NSTitlebarAccessoryViewController —— 它只能贴在窗口最右侧、
// 垂直位置由容器决定，实测比邻居低 8pt、右偏 19pt（用户说「往右下歪」）。
// 插进同一个 stack 后，行高/基线/间距全部由系统布局，天生对齐。
- (NSStackView *)titlebarButtonStack:(NSWindow *)w {
    NSView *theme = w.contentView.superview;
    if (!theme) return nil;
    __block NSStackView *best = nil;
    __block CGFloat bestX = -CGFLOAT_MAX;
    __block __weak void (^weakWalk)(NSView *);
    void (^walk)(NSView *);
    weakWalk = walk = ^(NSView *v) {
        if ([v isKindOfClass:[NSStackView class]]) {
            NSStackView *sv = (NSStackView *)v;
            NSInteger hits = 0;
            for (NSView *c in sv.arrangedSubviews) {
                NSRect f = c.frame;
                // 邻居按钮：高 18–26、宽 30–60 的小圆钮
                if (f.size.height >= 18 && f.size.height <= 26
                    && f.size.width >= 30 && f.size.width <= 60) hits++;
            }
            if (hits >= 2) {
                NSRect inWin = [sv convertRect:sv.bounds toView:nil];
                if (inWin.origin.x > bestX) { bestX = inWin.origin.x; best = sv; }
            }
        }
        for (NSView *sub in v.subviews) weakWalk(sub);
    };
    walk(theme);
    return best;
}

- (NSView *)titlebarContainerOf:(NSWindow *)w {
    NSView *theme = w.contentView.superview;
    if (!theme) return nil;
    __block NSView *found = nil;
    __block __weak void (^weakWalk)(NSView *);
    void (^walk)(NSView *);
    weakWalk = walk = ^(NSView *v) {
        if (found) return;
        if ([NSStringFromClass(v.class) containsString:@"TitlebarContainer"]) { found = v; return; }
        for (NSView *sub in v.subviews) weakWalk(sub);
    };
    walk(theme);
    return found;
}

- (void)ensureHostButton {
    NSWindow *w = [self hostWindow];
    if (!w) return;

    if (_lyricsButton && _lyricsButton.superview) {
        [self syncLyricsButtonFrame];
        return;
    }

    NSStackView *stack = [self titlebarButtonStack:w];
    NSView *container = [self titlebarContainerOf:w];
    if (!stack || !container) {
        // poll 每 0.1s 会再试，所以只记一次，免得刷日志
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            NMPLog(@"titlebar not ready: stack=%@ container=%@",
                  stack ? @"ok" : @"nil", container ? @"ok" : @"nil");
        }
        return;
    }

    // 图标尺寸/颜色按邻居实测：字形 16×16pt、纯白（截图量得 32×32 px @2x）
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:15
                                                        weight:NSFontWeightMedium];
    // ⚠️ captions.bubble 是较新系统才有的 SF Symbol。在 macOS 11/12 上取不到，
    //    按钮会变成「有位置、没图标」的空白钮 —— 用户看起来就是「没有歌词入口」。
    //    按新旧顺序回退，全都取不到就退成文字「词」。
    NSImage *icon = nil;
    for (NSString *sym in @[@"captions.bubble", @"text.bubble",
                            @"bubble.left", @"captions.bubble.fill"]) {
        icon = [[NSImage imageWithSystemSymbolName:sym accessibilityDescription:@"歌词"]
                imageWithSymbolConfiguration:cfg];
        if (icon) break;
    }
    if (icon) {
        icon.template = YES;
    } else {
        NMPLog(@"no SF Symbol available, falling back to text button");
    }
    NMPTitleButton *btn = [NMPTitleButton buttonWithImage:icon
                                                   target:self
                                                   action:@selector(toggleWindow:)];
    btn.bordered = NO;
    btn.imagePosition = icon ? NSImageOnly : NSNoImage;
    btn.imageScaling = NSImageScaleProportionallyDown;
    if (!icon) {
        btn.title = @"词";
        btn.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    }
    btn.contentTintColor = [NSColor whiteColor];
    btn.toolTip = @"歌词";
    btn.wantsLayer = YES;
    btn.layer.cornerRadius = 7;
    // 邻居底色实测 RGB(51,52,53)；我们原来是 0.22 白（渲染成 72,72,72），偏亮
    btn.layer.backgroundColor =
        [NSColor colorWithSRGBRed:51/255.0 green:52/255.0 blue:53/255.0 alpha:1.0].CGColor;
    // 跟着父视图右移：窗口改宽度时按钮和邻居一起走，不会等下一轮 poll 才跳过去
    btn.autoresizingMask = NSViewMinXMargin;

    // 挂在 NSTitlebarContainerView（普通 NSView）而不是 NSStackView 里：
    // stack 只把事件转给它自己托管的 arrangedSubviews，塞普通子视图能看见但点不动。
    // 放到最上层，否则会被标题栏背景/工具栏盖住（看得见点不着）
    [container addSubview:btn positioned:NSWindowAbove relativeTo:nil];
    _lyricsButton = btn;
    NMPLog(@"titlebar button installed");
    [self syncLyricsButtonFrame];
}

// 几何照抄邻居：同一 y、同高、同宽，挂在最左那个按钮的左边 10pt
- (void)hostWindowGeometryChanged:(NSNotification *)note {
    if (note.object == [self hostWindow]) [self syncLyricsButtonFrame];
    if (note.object == _lyricsWindow) [self layoutStage];
}

- (void)syncLyricsButtonFrame {
    NSButton *btn = _lyricsButton;
    if (!btn || !btn.superview) return;
    NSWindow *w = [self hostWindow];
    NSStackView *stack = w ? [self titlebarButtonStack:w] : nil;
    if (!stack) return;

    NSView *first = nil;
    for (NSView *c in stack.arrangedSubviews) {
        if (c.isHidden) continue;
        NSRect f = c.frame;
        if (f.size.height >= 18 && f.size.height <= 30 && f.size.width >= 30 && f.size.width <= 60) {
            if (!first || f.origin.x < first.frame.origin.x) first = c;
        }
    }
    if (!first) return;

    NSRect inWin = [first convertRect:first.bounds toView:nil];
    NSRect inContainer = [btn.superview convertRect:inWin fromView:nil];
    // 系统标题栏按钮的 frame 比它看得见的底色要大一圈（上下各约 1pt），
    // 我们的底色是用 layer 铺满 frame 的，照抄 frame 就会「比别人高一头」。
    // 这里把高度内缩 2pt 并垂直居中，视觉高度才和邻居齐平。
    CGFloat insetY = 1.0;
    NSRect target = NSMakeRect(inContainer.origin.x - 10 - inContainer.size.width,
                               inContainer.origin.y + insetY,
                               inContainer.size.width,
                               MAX(16, inContainer.size.height - insetY * 2));
    if (!NSEqualRects(btn.frame, target)) btn.frame = target;
}

// 把最右邻居的 frame 抄给歌词按钮（同一行、同高、间距 10）
// 把最右邻居的 frame 抄给我们的按钮（同一行、同高、间距 10）

// ---------------------------------------------------------------- AX 读取

- (void)walk:(AXUIElementRef)el depth:(int)depth
       title:(NSString *__autoreleasing *)title
      artist:(NSString *__autoreleasing *)artist
     elapsed:(NSString *__autoreleasing *)elapsed
   remaining:(NSString *__autoreleasing *)remaining
   playTitle:(NSString *__autoreleasing *)playTitle
    fraction:(double *)fraction {
    if (depth > 6) return;
    NSString *role = [self axString:el attr:kAXRoleAttribute];
    if ([role isEqualToString:@"AXStaticText"]) {
        NSString *desc = [self axString:el attr:kAXDescriptionAttribute];
        NSString *val = [self axString:el attr:kAXValueAttribute];
        if ([desc isEqualToString:@"Title"] && val.length) *title = val;
        else if ([desc isEqualToString:@"Artist"] && val.length) *artist = val;
        else if ([desc isEqualToString:@"Elapsed time"] && val.length) *elapsed = val;
        else if ([desc isEqualToString:@"Remaining time"] && val.length) *remaining = val;
    } else if ([role isEqualToString:@"AXButton"]) {
        NSString *t = [self axString:el attr:kAXTitleAttribute];
        if ([t containsString:@"Pause"] || [t containsString:@"Play"]) {
            if (t.length > (*playTitle).length) *playTitle = t;
        }
    }
    CFTypeRef kidsRef = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &kidsRef) == kAXErrorSuccess) {
        CFArrayRef kids = (CFArrayRef)kidsRef;
        CFIndex n = 0;
        for (CFIndex i = 0; i < CFArrayGetCount(kids); i++) {
            if (++n > 80) break;
            AXUIElementRef k = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
            [self walk:k depth:depth + 1 title:title artist:artist elapsed:elapsed
             remaining:remaining playTitle:playTitle fraction:fraction];
        }
        CFRelease(kidsRef);
    }
}

- (NSString *)axString:(AXUIElementRef)el attr:(CFStringRef)attr {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess) return nil;
    id obj = CFBridgingRelease(v);
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    return nil;
}

// ---------------------------------------------------------------- 渲染

- (double)currentPosition {
    if (!_playing) return _lockedSeconds;
    return _lockedSeconds + [[NSDate date] timeIntervalSinceDate:_lockedDate];
}

- (void)render {
    // 窗口关着就别画：一首新歌分析时 CPU/GPU 本来就满，我们不该再抢主线程
    if (!_lyricsWindow.isVisible) return;
    double pos = [self currentPosition];

    if (_stage.lines != _lines) _stage.lines = _lines;   // setter 内部会清缓存并标脏

    NSInteger idx = 0, word = -1;
    double prog = 0;
    BOOL before = YES;
    BOOL dots = NO;
    CGFloat dotFade = 0;

    if (_lines.count) {
        double t = pos - _offset;
        NSInteger i = [self activeLineAt:t];
        if (i >= 0) {
            before = NO;
            idx = i;
            NMPLine *line = _lines[i];
            if (line.words.count) {
                NSInteger k = [self activeWordIn:line.words at:t];
                word = k;
                double wStart = (k >= 0) ? line.words[k].time : line.time;
                double wEnd = (k + 1 < (NSInteger)line.words.count)
                              ? line.words[k + 1].time
                              : (line.time + MAX(line.duration, 0.2));   // 末词收在本行演唱结束时
                // 一句的最后一个词往往离下一句有间奏，按「到下一句」算会让这个字
                // 拖很久才亮完（看着像不亮）。词内进度最多拉 1.2 秒。
                if (wEnd - wStart > 1.2) wEnd = wStart + 1.2;
                prog = (wEnd > wStart) ? (t - wStart) / (wEnd - wStart) : 1.0;
            } else {
                // 兜底（正常解析后每行都有词级时间轴了）：
                // 用「实际演唱时长」而不是「到下一行的间隔」—— 否则间奏会被算进扫光。
                double dur = (line.duration > 0.05) ? line.duration : 4.0;
                prog = (t - line.time) / dur;
            }

            // ── 间奏判定：整行一次性判定，不再看「离下一行还剩多少秒」──
            // 旧条件 nextT - t > 0.9 太松：句尾正常换气（一两秒）就被判成间奏，
            // 于是到处都在闪点。现在改成看「这句唱完后到下句之间有多少纯静默」，
            // 静默超过 3 秒（慢歌按语速放宽）才认定是间奏。
            // 另外末句不判：歌词结束后还有大段尾奏，旧逻辑会一直亮着点。
            double lineEnd = line.time + MAX(line.duration, 0.3);
            NSInteger nx = i + 1;
            if (nx < (NSInteger)_lines.count && t >= lineEnd + 0.3) {
                double silence = _lines[nx].time - lineEnd;
                // 有真实逐字时间戳的行，收尾时刻是量出来的，门槛可以低一点；
                // 纯行级 LRC 只能靠字数估，误差大，门槛抬高到 3.6 秒起。
                double gate = line.timed ? MAX(3.0, 8.0 * _cadence)
                                         : MAX(3.6, 9.0 * _cadence);
                if (silence >= gate) {
                    dots = YES;
                    dotFade = MIN(1.0, (t - lineEnd - 0.3) / 0.30);
                }
            }
        }
    }

    if (![_stage.trackTitle isEqualToString:_trackTitle ?: @""]) {
        _stage.trackTitle = _trackTitle;
    }
    if (![_stage.trackArtist isEqualToString:_trackArtist ?: @""]) {
        _stage.trackArtist = _trackArtist;
    }

    // 流光背景开启时以 ~30fps 低开销驱动缓慢呼吸流动
    BOOL ambientTick = NO;
    if (_stage.ambientBg) {
        CFTimeInterval nowT = CACurrentMediaTime();
        if (nowT - _lastAmbientTick >= (1.0 / 30.0)) {
            _lastAmbientTick = nowT;
            ambientTick = YES;
        }
    }

    BOOL changed = (_stage.activeIndex != idx || _stage.activeWord != word ||
                    _stage.beforeStart != before ||
                    _stage.showDots != dots ||
                    fabs(_stage.dotFade - dotFade) > 0.01 ||
                    fabs(_stage.activeProgress - prog) > 0.002 ||
                    (dots && fabs(_stage.dotPhase - pos) > 0.03));
    _stage.activeIndex = idx;
    _stage.activeWord = word;
    _stage.activeProgress = prog;
    _stage.beforeStart = before;
    _stage.showDots = dots;
    _stage.dotFade = dots ? dotFade : 0;
    _stage.dotPhase = dots ? pos : 0;

    if (changed || _stage.animating || ambientTick) [_stage setNeedsDisplay:YES];
}

- (NSString *)clock:(double)s {
    if (s < 0) s = 0;
    return [NSString stringWithFormat:@"%02d:%02d", (int)(s / 60), ((int)s) % 60];
}

- (NSInteger)activeLineAt:(double)t {
    NSInteger lo = 0, hi = (NSInteger)_lines.count - 1, ans = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if (_lines[mid].time <= t) { ans = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    return ans;
}

- (NSInteger)activeWordIn:(NSArray<NMPWord *> *)words at:(double)t {
    NSInteger lo = 0, hi = (NSInteger)words.count - 1, ans = -1;
    while (lo <= hi) {
        NSInteger mid = (lo + hi) / 2;
        if (words[mid].time <= t) { ans = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    return ans;
}

// ---------------------------------------------------------------- 歌词加载

- (void)loadLyricsText:(NSString *)text sourceName:(NSString *)name {
    _lrcOffset = 0;
    NSArray<NMPLine *> *parsed = [self parseLyrics:text];
    if (!parsed.count) {
        return;
    }
    _lines = parsed;
    _lastLineIndex = -2;
}

- (BOOL)loadFromFileURL:(NSURL *)url {
    NSString *path = url.path;
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"lrc"]) {
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text) {
            text = [NSString stringWithContentsOfFile:path
                encoding:(NSStringEncoding)CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)
                   error:nil];
        }
        if (text.length) {
            if ([text characterAtIndex:0] == 0xFEFF) text = [text substringFromIndex:1];
            [self loadLyricsText:text sourceName:path];
            _boundTitle = _trackTitle;
            return YES;
        }
        return NO;
    }
    NSString *uslt = [self extractLyricsTextFromFile:url];
    if (uslt.length) {
        [self loadLyricsText:uslt sourceName:path];
        _boundTitle = _trackTitle;
        return YES;
    }
    return NO;
}

- (NSString *)decodeID3String:(const uint8_t *)p length:(NSUInteger)n encoding:(uint8_t)enc {
    if (!p || n == 0) return nil;
    NSString *text = nil;
    NSData *d = [NSData dataWithBytes:p length:n];
    if (enc == 1 || enc == 2) {
        if (enc == 1) {
            const uint8_t *b = d.bytes;
            BOOL hasBOM = n >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF));
            if (!hasBOM) {
                uint8_t bom[2] = {0xFF, 0xFE};
                NSMutableData *m = [NSMutableData dataWithBytes:bom length:2];
                [m appendData:d];
                d = m;
            }
            text = [[NSString alloc] initWithData:d encoding:NSUTF16StringEncoding];
            if (!text) text = [[NSString alloc] initWithData:d encoding:NSUTF16LittleEndianStringEncoding];
        } else {
            text = [[NSString alloc] initWithData:d encoding:NSUTF16BigEndianStringEncoding];
        }
    } else if (enc == 3) {
        text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!text) {
            text = [[NSString alloc] initWithData:d
                encoding:(NSStringEncoding)CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
        }
    } else {
        // enc=0 名义上是 Latin1，但国产软件常塞 GBK —— 有高位字节先按 GB18030 解
        BOOL high = NO;
        for (NSUInteger i = 0; i < n; i++) { if (p[i] > 127) { high = YES; break; } }
        if (high) {
            text = [[NSString alloc] initWithData:d
                encoding:(NSStringEncoding)CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
        }
        if (!text) text = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    }
    if (text.length && [text characterAtIndex:0] == 0xFEFF) text = [text substringFromIndex:1];
    return text.length ? text : nil;
}

// 找终止符长度（UTF-16 双 NUL，其余单 NUL）
- (NSUInteger)id3TermLength:(const uint8_t *)p length:(NSUInteger)n encoding:(uint8_t)enc {
    if (enc == 1 || enc == 2) {
        for (NSUInteger i = 0; i + 1 < n; i += 2) {
            if (p[i] == 0 && p[i + 1] == 0) return i + 2;
        }
        return n;
    }
    for (NSUInteger i = 0; i < n; i++) { if (p[i] == 0) return i + 1; }
    return n;
}

// SYLT（同步歌词）→ LRC 文本
- (NSString *)lrcFromSYLT:(const uint8_t *)p length:(NSUInteger)n {
    if (n < 7) return nil;
    uint8_t enc = p[0];
    uint8_t timeFormat = p[4];
    const uint8_t *q = p + 6;
    NSUInteger left = n - 6;
    NSUInteger term = [self id3TermLength:q length:left encoding:enc];
    if (term >= left) return nil;
    q += term; left -= term;

    NSMutableString *out = [NSMutableString string];
    while (left > 4) {
        NSUInteger t = [self id3TermLength:q length:left encoding:enc];
        if (t >= left || left < t + 4) break;
        NSString *txt = [self decodeID3String:q length:(t > 0 ? t - (enc == 1 || enc == 2 ? 2 : 1) : 0)
                                     encoding:enc];
        q += t; left -= t;
        uint32_t ts = ((uint32_t)q[0] << 24) | ((uint32_t)q[1] << 16) |
                      ((uint32_t)q[2] << 8) | (uint32_t)q[3];
        q += 4; left -= 4;
        double ms = (timeFormat == 2) ? ts * 12.0 : (double)ts;   // MPEG 帧近似
        if (txt.length) {
            [out appendFormat:@"[%02d:%02d.%03d]%@\n",
                (int)(ms / 60000), (int)(fmod(ms, 60000) / 1000), (int)fmod(ms, 1000), txt];
        }
    }
    return out.length ? out : nil;
}

// 解析 ID3v2 标签，一次读取同时取歌词（USLT / SYLT / TXXX / ULT）与内嵌封面（APIC / PIC）
- (NSString *)extractLyricsTextFromFile:(NSURL *)url {
    return [self extractLyricsTextFromFile:url outArtwork:NULL];
}

- (NSImage *)extractArtworkViaAVAsset:(NSURL *)url {
    if (!url) return nil;
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        for (AVMetadataItem *item in asset.commonMetadata) {
            if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtwork]) {
                NSData *data = item.dataValue;
                if (!data && [item.value isKindOfClass:[NSData class]]) data = (NSData *)item.value;
                if (data.length > 64) {
                    NSImage *img = [[NSImage alloc] initWithData:data];
                    if (img) return img;
                }
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

- (NSString *)extractLyricsTextFromFile:(NSURL *)url outArtwork:(NSImage *__autoreleasing *)outArtwork {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!fh) return nil;
    NSData *hdr = [fh readDataOfLength:10];
    if (hdr.length < 10 || memcmp(hdr.bytes, "ID3", 3) != 0) {
        [fh closeFile];
        if (outArtwork) *outArtwork = [self extractArtworkViaAVAsset:url];
        return nil;
    }
    const uint8_t *h = hdr.bytes;
    uint8_t ver = h[3];
    uint8_t flags = h[5];
    NSUInteger tagSize = ((NSUInteger)(h[6] & 0x7f) << 21) | ((NSUInteger)(h[7] & 0x7f) << 14)
                       | ((NSUInteger)(h[8] & 0x7f) << 7)  | (NSUInteger)(h[9] & 0x7f);
    if (tagSize == 0 || tagSize > 16 * 1024 * 1024) {
        [fh closeFile];
        if (outArtwork) *outArtwork = [self extractArtworkViaAVAsset:url];
        return nil;
    }
    NSMutableData *body = [[fh readDataOfLength:tagSize] mutableCopy];
    [fh closeFile];
    if (!body.length) return nil;

    if (flags & 0x80) {
        NSMutableData *fixed = [NSMutableData dataWithCapacity:body.length];
        const uint8_t *b = body.bytes;
        for (NSUInteger i = 0; i < body.length; i++) {
            uint8_t c = b[i];
            [fixed appendBytes:&c length:1];
            if (c == 0xFF && i + 1 < body.length && b[i + 1] == 0x00) i++;
        }
        body = fixed;
    }

    const uint8_t *b = body.bytes;
    NSUInteger n = body.length;
    NSUInteger pos = 0;
    NSString *plainLyrics = nil;
    NSString *timestamped = nil;
    NSImage *artwork = nil;

    while (pos + (ver == 2 ? 6 : 10) <= n) {
        char id[5] = {0};
        NSUInteger fsize = 0;
        NSUInteger hdrLen = 0;
        if (ver == 2) {
            memcpy(id, b + pos, 3);
            fsize = ((NSUInteger)b[pos+3] << 16) | ((NSUInteger)b[pos+4] << 8) | b[pos+5];
            hdrLen = 6;
        } else {
            memcpy(id, b + pos, 4);
            if (ver >= 4) {
                fsize = ((NSUInteger)(b[pos+4] & 0x7f) << 21) | ((NSUInteger)(b[pos+5] & 0x7f) << 14)
                      | ((NSUInteger)(b[pos+6] & 0x7f) << 7)  | (NSUInteger)(b[pos+7] & 0x7f);
            } else {
                fsize = ((NSUInteger)b[pos+4] << 24) | ((NSUInteger)b[pos+5] << 16)
                      | ((NSUInteger)b[pos+6] << 8)  | (NSUInteger)b[pos+7];
            }
            hdrLen = 10;
        }
        if (id[0] == 0 || fsize == 0 || pos + hdrLen + fsize > n) break;
        const uint8_t *fp = b + pos + hdrLen;
        NSUInteger fl = fsize;

        if (strcmp(id, "USLT") == 0 || strcmp(id, "ULT") == 0) {
            if (fl > 4) {
                uint8_t enc = fp[0];
                const uint8_t *rest = fp + 4;
                NSUInteger rl = fl - 4;
                NSUInteger term = [self id3TermLength:rest length:rl encoding:enc];
                NSString *txt = (term < rl)
                    ? [self decodeID3String:rest + term length:rl - term encoding:enc] : nil;
                if (txt.length) {
                    if (!plainLyrics.length) plainLyrics = txt;
                    if ([txt rangeOfString:@"["].location != NSNotFound && !timestamped.length) {
                        timestamped = txt;
                    }
                }
            }
        } else if (strcmp(id, "SYLT") == 0) {
            NSString *lrc = [self lrcFromSYLT:fp length:fl];
            if (lrc.length && !timestamped.length) timestamped = lrc;
        } else if (strcmp(id, "TXXX") == 0 && fl > 2) {
            uint8_t enc = fp[0];
            const uint8_t *rest = fp + 1;
            NSUInteger rl = fl - 1;
            NSUInteger term = [self id3TermLength:rest length:rl encoding:enc];
            NSString *desc = (term > 0 && term <= rl)
                ? [self decodeID3String:rest length:(term - (enc == 1 || enc == 2 ? 2 : 1)) encoding:enc] : nil;
            NSString *val = (term < rl)
                ? [self decodeID3String:rest + term length:rl - term encoding:enc] : nil;
            NSString *dl = desc.lowercaseString;
            if (val.length && ([dl containsString:@"lyric"] || [dl containsString:@"歌词"]
                               || [dl containsString:@"usk"] || [dl containsString:@"uslt"])) {
                if (!plainLyrics.length) plainLyrics = val;
            }
        } else if (outArtwork && !artwork && (strcmp(id, "APIC") == 0 || strcmp(id, "PIC") == 0) && fl > 16) {
            // ID3v2.3/2.4 APIC: [enc:1][mime NUL][picType:1][desc NUL][imageData]
            // ID3v2.2 PIC:      [enc:1][fmt:3][picType:1][desc NUL][imageData]
            uint8_t enc = fp[0];
            NSUInteger off = 1;
            if (ver == 2) {
                off += 3;
            } else {
                while (off < fl && fp[off] != 0) off++;
                off++; // skip NUL
            }
            if (off + 1 < fl) {
                off++; // skip picType
                NSUInteger dterm = [self id3TermLength:fp + off length:fl - off encoding:enc];
                off += dterm;
                if (off < fl && fl - off > 64) {
                    NSData *imgData = [NSData dataWithBytes:fp + off length:fl - off];
                    NSImage *img = [[NSImage alloc] initWithData:imgData];
                    if (img) artwork = img;
                }
            }
        }
        pos += hdrLen + fsize;
    }
    if (outArtwork) {
        *outArtwork = artwork ?: [self extractArtworkViaAVAsset:url];
    }
    return timestamped.length ? timestamped : plainLyrics;
}

// ---------------------------------------------------------------- 歌词与封面定位（世代令牌防竞态）

- (void)resolveLyricsForTitle:(NSString *)title artist:(NSString *)artist {
    NSUInteger gen = _resolveGeneration;
    NSString *captured = LastAudioPath;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *foundPath = nil;

        if (captured.length && [[NSFileManager defaultManager] fileExistsAtPath:captured]) {
            NSString *name = captured.lastPathComponent.stringByDeletingPathExtension;
            NSString *nName = NormalizeTitle(name);
            NSString *nTitle = NormalizeTitle(title);
            if (nTitle.length && (nName.length == 0 ||
                [nName containsString:nTitle] || [nTitle containsString:nName] ||
                [nName containsString:NormalizeTitle(artist ?: @"")])) {
                foundPath = captured;
            }
        }

        if (!foundPath) foundPath = [self quickFind:title];

        if (!foundPath) {
            NSString *folder = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefFolder];
            if (!folder.length) folder = kDefaultFolder;
            foundPath = [self scanFolder:[folder stringByExpandingTildeInPath]
                                   title:title timeout:3.0];
        }

        NSArray<NMPLine *> *lines = nil;
        double parsedOffset = 0;
        NSImage *artwork = nil;
        NSString *okPath = nil;

        if (foundPath && [self parseFileAtPath:foundPath outLines:&lines outOffset:&parsedOffset outArtwork:&artwork]) {
            okPath = foundPath;
        } else if (captured.length && [self parseFileAtPath:captured outLines:&lines outOffset:&parsedOffset outArtwork:&artwork]) {
            okPath = captured;
        } else if (!artwork && (foundPath.length || captured.length)) {
            NSString *artSrc = foundPath.length ? foundPath : captured;
            [self extractLyricsTextFromFile:[NSURL fileURLWithPath:artSrc] outArtwork:&artwork];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_resolveGeneration) return; // 已有更新的切歌请求，丢弃过期结果
            if (artwork) self->_stage.artwork = artwork;
            if (okPath && lines.count) {
                [self commitParsedLines:lines offset:parsedOffset sourcePath:okPath];
                return;
            }
            if (self->_retryCount < 6 && self->_trackTitle.length && LastAudioPath.length) {
                self->_retryCount++;
                NSString *cap = LastAudioPath;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gen == self->_resolveGeneration && !self->_lines.count) {
                        [self retryCapturedPath:cap generation:gen];
                    }
                });
            }
        });
    });
}

- (BOOL)parseFileAtPath:(NSString *)path
               outLines:(NSArray<NMPLine *> *__autoreleasing *)outLines
              outOffset:(double *)outOffset
             outArtwork:(NSImage *__autoreleasing *)outArtwork {
    if (!path.length) return NO;
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *text = nil;
    NSImage *art = nil;
    if ([ext isEqualToString:@"lrc"]) {
        text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text) {
            text = [NSString stringWithContentsOfFile:path
                encoding:(NSStringEncoding)CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)
                   error:nil];
        }
        if (text.length && [text characterAtIndex:0] == 0xFEFF) text = [text substringFromIndex:1];
    } else {
        text = [self extractLyricsTextFromFile:[NSURL fileURLWithPath:path] outArtwork:&art];
    }
    if (outArtwork && art) *outArtwork = art;
    if (!text.length) return NO;
    double locOffset = 0;
    NSArray<NMPLine *> *parsed = [self parseLyrics:text outOffset:&locOffset];
    if (!parsed.count) return NO;
    if (outLines) *outLines = parsed;
    if (outOffset) *outOffset = locOffset;
    return YES;
}

- (void)commitParsedLines:(NSArray<NMPLine *> *)lines offset:(double)lrcOff sourcePath:(NSString *)path {
    if (!lines.count) return;
    _lines = lines;
    _lrcOffset = lrcOff;
    _lastLineIndex = -2;
    _boundTitle = _trackTitle;
}

- (void)retryCapturedPath:(NSString *)cap generation:(NSUInteger)gen {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NMPLine *> *lines = nil;
        double parsedOffset = 0;
        NSImage *artwork = nil;
        BOOL ok = [self parseFileAtPath:cap outLines:&lines outOffset:&parsedOffset outArtwork:&artwork];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_resolveGeneration) return;
            if (artwork) self->_stage.artwork = artwork;
            if (ok && lines.count) {
                [self commitParsedLines:lines offset:parsedOffset sourcePath:cap];
            } else if (self->_retryCount < 6 && self->_trackTitle.length && LastAudioPath.length) {
                self->_retryCount++;
                NSString *c2 = LastAudioPath;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gen == self->_resolveGeneration && !self->_lines.count) {
                        [self retryCapturedPath:c2 generation:gen];
                    }
                });
            }
        });
    });
}

/// 常见位置限时查找（~/Music、iCloud 音乐、~/Downloads）
/// Spotlight 查找（mdfind -name）：走索引不枚举目录，毫秒级。
/// 目录枚举对 iCloud 占位文件会一卡几十秒（超时检查轮不到执行），不许再当主力。
- (NSString *)spotlightFind:(NSString *)title {
    NSString *needle = NormalizeTitle(title);
    if (!needle.length) return nil;
    NSArray *queries = [NSArray arrayWithObjects:needle, (title ?: @""), nil];
    for (NSUInteger qi = 0; qi < queries.count; qi++) {
        NSString *q = [queries[qi] stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
        if (q.length < 2) continue;
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/mdfind";
        task.arguments = @[@"-name", q];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = [NSPipe pipe];
        @try { [task launch]; } @catch (NSException *e) { continue; }
        // 3 秒硬超时：轮询进程状态（mdfind 正常毫秒级返回）
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while ([task isRunning] && [limit timeIntervalSinceNow] > 0) {
            usleep(50000);
        }
        if ([task isRunning]) {
            [task terminate];
            continue;
        }
        NSData *out = nil;
        @try { out = [pipe.fileHandleForReading readDataToEndOfFile]; } @catch (NSException *e) { continue; }
        NSString *text = out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : nil;
        if (!text.length) continue;
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            NSString *lp = [line stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
            if (!lp.length) continue;
            NSString *ext = lp.pathExtension.lowercaseString;
            if (![@[@"mp3", @"m4a", @"flac", @"wav", @"lrc"] containsObject:ext]) continue;
            NSString *nName = NormalizeTitle(lp.lastPathComponent.stringByDeletingPathExtension);
            if ([nName containsString:needle] || [needle containsString:nName]) {
                return lp;
            }
        }
    }
    return nil;
}

- (NSString *)quickFind:(NSString *)title {
    NSString *hit = [self spotlightFind:title];
    if (hit) return hit;
    // 兜底：本地小目录快速扫（带条目上限，防 iCloud 挂死）
    NSArray *roots = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Music/Music/Media.localized"],
    ];
    for (NSString *root in roots) {
        hit = [self scanFolder:root title:title timeout:2.0];
        if (hit) return hit;
    }
    return nil;
}

- (NSString *)scanFolder:(NSString *)root title:(NSString *)title timeout:(NSTimeInterval)timeout {
    if (!root.length || ![[NSFileManager defaultManager] fileExistsAtPath:root]) return nil;
    NSString *needle = NormalizeTitle(title);
    if (!needle.length) return nil;

    __block NSString *hit = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager]
        enumeratorAtPath:root];
    NSUInteger seen = 0;
    for (NSString *rel in e) {
        // 双保险：时间 deadline + 条目上限。iCloud 枚举单条目可能卡几秒，
        // 只靠时间检查可能一直轮不到执行（「40 秒才出歌词」的根因之一）。
        if (++seen > 4000) break;
        if ([deadline timeIntervalSinceNow] < 0) break;
        NSString *ext = rel.pathExtension.lowercaseString;
        if (![@[@"mp3", @"m4a", @"flac", @"wav", @"lrc"] containsObject:ext]) continue;
        NSString *name = rel.lastPathComponent.stringByDeletingPathExtension;
        NSString *norm = NormalizeTitle(name);
        if (norm.length && ([norm containsString:needle] || [needle containsString:norm])) {
            hit = [root stringByAppendingPathComponent:rel];
            if ([ext isEqualToString:@"lrc"]) break;   // 同名 .lrc 优先
        }
    }
    return hit;
}

static NSInteger NMPVisibleChars(NSString *s) {
    NSInteger n = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == 0x3000 || c == 0x00a0) continue;
        n++;
    }
    return n;
}

/// 补全时间轴：算出「每行真正唱多久」，并给没有词级时间戳的行合成词级时间轴。
///
/// 为什么要这一步：普通 LRC 只有行时间。旧代码把「下一行 - 本行」整段
/// 当成本行的扫光时长 —— 中间只要隔着间奏，这一行就被摊成十几秒慢慢扫，
/// 而实际上词早就唱完进间奏了。用户看到的就是「间奏前的歌词放慢动作」。
///
/// 判定方式：先估「唱这行需要多久」（字数 x 每字秒数），再和行间隔比。
/// 间隔明显更长 => 多出来的部分是间奏，扫光只扫到唱完为止。
- (void)synthesizeTimings:(NSMutableArray<NMPLine *> *)lines {
    if (!lines.count) return;

    // (1) 每字秒数：优先用真实词级时间戳反推（那是歌手实际唱出来的密度）
    NSMutableArray<NSNumber *> *samples = [NSMutableArray array];
    for (NMPLine *l in lines) {
        if (l.words.count < 2) continue;
        double d = l.words.lastObject.time - l.words.firstObject.time;
        NSInteger n = NMPVisibleChars(l.text);
        if (d > 0.08 && n >= 2) [samples addObject:@(d / (double)n)];
    }
    double rate = 0;
    if (samples.count) {
        [samples sortUsingSelector:@selector(compare:)];
        rate = samples[samples.count / 2].doubleValue;   // 中位数，间奏行污染不到它
    }

    // 整首都没有词级时间戳时，用「行间隔中位数 / 字数中位数」量出这本曲子的语速，
    // 比写死 0.34 准得多（快歌慢歌差别很大）。中位数同样抗间奏污染。
    if (rate <= 0) {
        NSMutableArray<NSNumber *> *gaps = [NSMutableArray array];
        NSMutableArray<NSNumber *> *chars = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
            NMPLine *l = lines[i];
            NSInteger n = NMPVisibleChars(l.text);
            if (n < 1) continue;
            [chars addObject:@((double)n)];
            if (i + 1 < (NSInteger)lines.count) {
                double g = lines[i + 1].time - l.time;
                if (g > 0.2 && g < 60) [gaps addObject:@(g)];
            }
        }
        if (gaps.count >= 3) {
            [gaps sortUsingSelector:@selector(compare:)];
            [chars sortUsingSelector:@selector(compare:)];
            double mg = gaps[gaps.count / 2].doubleValue;
            double mc = MAX(2.0, chars[chars.count / 2].doubleValue);
            // 行间隔里天然含「句尾气口」，直接除会系统性高估语速。
            // 经验上一行真正在唱的时间约占间隔的七成。
            rate = mg * 0.72 / mc;
        }
    }
    if (rate <= 0) rate = 0.34;   // 中文流行歌经验值：一字约 0.3 秒
    rate = MIN(MAX(rate, 0.15), 0.55);
    _cadence = rate;              // 间奏门槛跟着语速走：慢歌的留白天然更长

    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NMPLine *l = lines[i];
        double gap = 4.0;
        if (i + 1 < (NSInteger)lines.count) gap = lines[i + 1].time - l.time;
        if (gap <= 0.01) gap = 4.0;

        // (2) 这一行要唱多久
        double dur;
        if (l.words.count) {
            // 有真实词级时间戳：末词起唱时刻 + 末词自己占的时长
            // （l.time 已经含过 _lrcOffset，这里不能再加一次，否则偏移会被算两遍）
            NMPWord *last = l.words.lastObject;
            double end = last.time + NMPVisibleChars(last.text) * rate;
            dur = end - l.time;
        } else {
            double natural = MAX(1, NMPVisibleChars(l.text)) * rate;
            // 「允许的自然浮动」：字数估出来的时长再放宽 (x1.8 + 1.2 秒)，
            // 短句拖长音、句尾留气口都不会被误判成间奏；
            // 只有间隔远超这个余量，才认定中间是间奏，扫光只扫到唱完。
            double allowance = natural * 1.8 + 1.2;
            dur = (gap <= allowance) ? gap : natural * 1.15;
        }
        dur = MAX(dur, 0.45);
        if (dur > gap) dur = gap;
        l.duration = dur;

        // (3) 没有词级时间戳的行，按「连续同类型字符」切块补一份
        //    拉丁字母/数字整词一块（长单词占时更久），汉字一字一块，空格算轻量
        if (l.words.count) continue;
        NSString *t = l.text;
        if (!t.length) continue;

        NSMutableArray<NSString *> *pieces = [NSMutableArray array];
        NSMutableArray<NSNumber *> *weights = [NSMutableArray array];
        NSUInteger p = 0;
        while (p < t.length) {
            NSUInteger s0 = p;
            unichar c = [t characterAtIndex:p];
            BOOL isSpace = (c == ' ' || c == '\t' || c == 0x3000 || c == 0x00a0);
            BOOL isLatin = (!isSpace && c < 128 &&
                            [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]);
            p++;
            while (p < t.length) {
                unichar c2 = [t characterAtIndex:p];
                BOOL s2 = (c2 == ' ' || c2 == '\t' || c2 == 0x3000 || c2 == 0x00a0);
                BOOL l2 = (!s2 && c2 < 128 &&
                           [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c2]);
                if (s2 != isSpace || l2 != isLatin) break;
                p++;
            }
            [pieces addObject:[t substringWithRange:NSMakeRange(s0, p - s0)]];
            [weights addObject:@(isSpace ? 0.2 : (double)(p - s0))];
        }

        double totalW = 0;
        for (NSNumber *x in weights) totalW += x.doubleValue;
        if (totalW <= 0) continue;

        NSMutableArray<NMPWord *> *made = [NSMutableArray array];
        double acc = 0;
        for (NSUInteger k = 0; k < pieces.count; k++) {
            NMPWord *w = [NMPWord wordWithTime:l.time + l.duration * (acc / totalW)];
            w.text = pieces[k];
            acc += weights[k].doubleValue;
            [made addObject:w];
        }
        l.words = made;
    }
}

/// 统一歌词解析 —— 网易云 / QQ音乐 / 酷我 / 酷狗 的内嵌歌词通吃：
///
///   行级 LRC：        [00:32.444]戏一折 水袖起落
///   词级 A2（网易云）： <02:50.610>真<02:50.950>的<02:51.390>希望
///   混合：            [00:32.4]<00:32.4>戏一折 <00:34.1>水袖起落
///   酷我头：          [kuwo:0141] [ver:v1.0] [ti:赤伶]  → 自动跳过
///
/// 同一行两种时间戳都有时，词级优先（逐字高亮靠它）。
- (NSArray<NMPLine *> *)parseLyrics:(NSString *)text {
    double off = 0;
    NSArray<NMPLine *> *res = [self parseLyrics:text outOffset:&off];
    _lrcOffset = off;
    return res;
}

- (NSArray<NMPLine *> *)parseLyrics:(NSString *)text outOffset:(double *)outOffset {
    if (!text.length) return nil;
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
            stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    double localOffset = 0;
    NSMutableArray<NMPLine *> *out = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;

        if ([line hasPrefix:@"[offset:"]) {
            NSRange close = [line rangeOfString:@"]"];
            if (close.location != NSNotFound) {
                double ms = [[line substringWithRange:NSMakeRange(8, close.location - 8)] doubleValue];
                localOffset = ms / 1000.0;
            }
            continue;
        }

        NSMutableArray<NSNumber *> *lineTimes = [NSMutableArray array];
        NSUInteger i = 0;
        while (i < line.length && [line characterAtIndex:i] == '[') {
            NSRange close = [line rangeOfString:@"]" options:0 range:NSMakeRange(i, line.length - i)];
            if (close.location == NSNotFound) break;
            double t = ParseClock([line substringWithRange:NSMakeRange(i + 1, close.location - i - 1)]);
            if (t < 0) break;
            [lineTimes addObject:@(t)];
            i = NSMaxRange(close);
        }
        NSString *body = [[line substringFromIndex:i] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (!body.length) continue;

        NSMutableArray<NMPWord *> *words = [NSMutableArray array];
        NMPWord *current = nil;
        NSMutableString *headPlain = [NSMutableString string];
        NSUInteger k = 0;
        while (k < body.length) {
            unichar ch = [body characterAtIndex:k];
            if (ch == '<') {
                NSRange close = [body rangeOfString:@">" options:0 range:NSMakeRange(k, body.length - k)];
                if (close.location != NSNotFound) {
                    double t = ParseClock([body substringWithRange:NSMakeRange(k + 1, close.location - k - 1)]);
                    if (t >= 0) {
                        current = [NMPWord wordWithTime:t];
                        [words addObject:current];
                        k = NSMaxRange(close);
                        continue;
                    }
                }
            }
            NSString *piece = [body substringWithRange:NSMakeRange(k, 1)];
            if (current) current.text = [current.text stringByAppendingString:piece];
            else [headPlain appendString:piece];
            k++;
        }

        if (words.count) {
            NSMutableString *raw = [headPlain mutableCopy];
            for (NMPWord *w in words) [raw appendString:w.text];

            NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
            NSInteger lead = 0, tail = (NSInteger)raw.length;
            while (lead < tail && [ws characterIsMember:[raw characterAtIndex:lead]]) lead++;
            while (tail > lead && [ws characterIsMember:[raw characterAtIndex:tail - 1]]) tail--;
            if (tail <= lead) continue;
            NSRange keep = NSMakeRange(lead, tail - lead);

            NSInteger cursor = (NSInteger)headPlain.length;
            for (NMPWord *w in words) {
                NSInteger ws0 = cursor, we0 = cursor + (NSInteger)w.text.length;
                NSInteger s2 = MAX(ws0, lead), e2 = MIN(we0, tail);
                w.text = (e2 > s2) ? [raw substringWithRange:NSMakeRange(s2, e2 - s2)] : @"";
                cursor = we0;
            }
            NSMutableArray<NMPWord *> *kept = [NSMutableArray array];
            for (NMPWord *w in words) if (w.text.length) [kept addObject:w];
            words = kept;
            if (!words.count) continue;

            NSString *trimmed = [raw substringWithRange:keep];
            NMPLine *l = [NMPLine new];
            l.time = MAX(0, words.firstObject.time + localOffset);
            l.text = trimmed;
            l.words = words;
            l.timed = (words.count >= 2);
            [out addObject:l];
        } else if (lineTimes.count) {
            NSString *lineText = [headPlain stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!lineText.length) continue;
            for (NSNumber *t in lineTimes) {
                NMPLine *l = [NMPLine new];
                l.time = MAX(0, t.doubleValue + localOffset);
                l.text = lineText;
                l.words = nil;
                [out addObject:l];
            }
        }
    }
    if (outOffset) *outOffset = localOffset;
    if (!out.count) return nil;
    [out sortUsingComparator:^NSComparisonResult(NMPLine *a, NMPLine *b) {
        return (a.time == b.time) ? NSOrderedSame
             : ((a.time < b.time) ? NSOrderedAscending : NSOrderedDescending);
    }];
    [self synthesizeTimings:out];   // 定每行演唱时长 + 补词级时间轴（治间奏慢动作）
    return out;
}

// ---------------------------------------------------------------- 动作

- (void)toggleWindow:(id)sender {
    if (!_lyricsWindow) return;
    if (_toggling) return;   // 防抖：动画中再点直接忽略，防两次动画交叉卡死
    _toggling = YES;
    if (_lyricsWindow.isVisible) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
            c.duration = 0.15;
            [[_lyricsWindow animator] setAlphaValue:0];
        } completionHandler:^{
            [self->_lyricsWindow orderOut:nil];
            [self->_lyricsWindow setAlphaValue:1];
            self->_toggling = NO;
        }];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
        [_lyricsWindow setAlphaValue:0];
        [_lyricsWindow makeKeyAndOrderFront:nil];
        [self layoutStage];   // 窗口真出现后 safeAreaInsets 才有值，这时重算一次
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
            c.duration = 0.15;
            [[_lyricsWindow animator] setAlphaValue:1];
        } completionHandler:^{
            self->_toggling = NO;
        }];
    }
}

// 红色关闭钮 = 隐藏（窗口保留，按钮可再开）
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == _lyricsWindow) {
        [self toggleWindow:nil];
        return NO;
    }
    return YES;
}

// 字号不再可调：完全跟随窗口尺寸（NMPStageView.fontSize 里算）
- (void)fontBigger:(id)sender  {}
- (void)fontSmaller:(id)sender {}

// ---------------------------------------------------------------- 拖放

@end

// ================================================================ 入口

__attribute__((constructor))
static void libNMPLyricsEntry(void) {
    // 菜单栏不做运行时汉化：曾用 setter swizzle + 2 秒定时遍历强刷，
    // 那是定时炸弹（会污染全局方法分发、还会跟 NMP 重建菜单打架）。
    // 现在只有 zh-Hans.lproj 这套正规本地化，翻不到的就保持英文。

    // 文件捕获钩子（static 持久存储，修复栈上局部变量悬空指针隐患）
    static struct rebinding_entry r1 = {"open",      (void *)hooked_open,      (void **)&orig_open,   NULL};
    static struct rebinding_entry r2 = {"openat",    (void *)hooked_openat,    (void **)&orig_openat, NULL};
    static struct rebinding_entry r3 = {"fopen",     (void *)hooked_fopen,     (void **)&orig_fopen,  NULL};
    r1.next = &r2; r2.next = &r3; r3.next = NULL;
    g_rebindings = &r1;
    rebind_symbols();

    NMPLog(@"dylib loaded (pid=%d)", getpid());

    dispatch_async(dispatch_get_main_queue(), ^{
        NMPLog(@"registering launch observer");
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationDidFinishLaunchingNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
                        NMPLog(@"didFinishLaunching received");
                        [NMPLyricsController shared];
                    }];

        // 兜底：这个 block 本身可能晚于「启动完成」通知才被执行
        // （不同机器 / 不同磁盘速度下时序不一样），那样通知永远收不到，
        // controller 不创建 → 标题栏没有按钮、⌘L 也没反应。
        // shared 是 dispatch_once，重复调用是安全的。
        for (double d = 0.5; d <= 3.05; d += 1.0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if ([NSApp isRunning]) {
                    NMPLog(@"fallback init at %.1fs (windows=%lu)",
                          d, (unsigned long)[[NSApp windows] count]);
                    [NMPLyricsController shared];
                }
            });
        }
    });
}
