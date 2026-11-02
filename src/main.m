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
#import <dlfcn.h>
#import <fcntl.h>
#import <stdarg.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>

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

static NSString *const kPrefFolder   = @"cn.renqiaoyi.lyrics.folder";
static NSString *const kPrefOnTop    = @"cn.renqiaoyi.lyrics.onTop";
static NSString *const kPrefFontScale = @"cn.renqiaoyi.lyrics.fontScale";
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
@property (nonatomic, copy)   NSString *text;
@property (nonatomic, strong) NSArray<NMPWord *> *words;
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

// ================================================================ 歌词舞台视图
// 上一句暗 / 当前句大字逐字扫光 / 下一句暗，整体垂直居中 —— 投影给学生看。
//
// 这一版重写的四个原因：
//  1. 扫光原来是一整个矩形裁剪，长句换行成两行时**两行会同时亮**（用户反馈）。
//     改成按字形范围绘制：clip 到第 N 个字符，换行也只会一行一行往下扫。
//  2. 英文歌词原来没有空格：解析阶段把每个词的首尾空白都 trim 掉了。
//  3. 帧率低：原来每帧给整首歌**每一行**都建一次富文本 + 量一次尺寸。
//     现在只给屏幕内的几行建，行高按 (行号, 距离档位) 缓存。
//  4. 去掉了 NSShadow（纯黑底上根本看不出阴影，却最烧 GPU）。

static inline CGFloat NMPClassScale(NSInteger cls) {
    switch (cls) {
        case 0:  return 1.00;
        case 1:  return 0.56;
        case 2:  return 0.48;
        case 3:  return 0.43;
        default: return 0.40;
    }
}
static inline CGFloat NMPClassAlpha(NSInteger cls) {
    switch (cls) {
        case 0:  return 1.00;
        case 1:  return 0.50;
        case 2:  return 0.34;
        case 3:  return 0.24;
        default: return 0.16;
    }
}

@interface NMPStageView : NSView
@property (nonatomic, strong) NSArray<NMPLine *> *lines;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, assign) NSInteger activeWord;
@property (nonatomic, assign) BOOL beforeStart;
@property (nonatomic, assign) CGFloat activeProgress;
@property (nonatomic, readonly) CGFloat fontSize;   // 窗口尺寸 × 用户倍率
@property (nonatomic, assign) CGFloat fontScale;    // 滑条：0.6 – 2.0
@property (nonatomic, assign) BOOL animating;       // 滚动还没停 → 需要继续出帧
@end

@implementation NMPStageView {
    NSMutableDictionary<NSNumber *, NSNumber *> *_textH;   // (行号<<3 | 档位) -> 文字高度
    CGFloat _cacheFS;
    CGFloat _cacheW;
    CGFloat _scrollY;
    NSGradient *_gTop;
    NSGradient *_gBot;
    CGFloat _gHeight;
}

- (BOOL)isFlipped { return YES; }

- (void)setLines:(NSArray<NMPLine *> *)lines {
    if (_lines == lines) return;
    _lines = lines;
    [_textH removeAllObjects];
    _scrollY = 0;
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [_textH removeAllObjects];
    [self setNeedsDisplay:YES];
}

// 字号不再由滑块决定，完全跟随窗口：高度为主、宽度兜底，保证窄窗不溢出
- (CGFloat)fontSize {
    NSRect b = self.bounds;
    CGFloat scale = (self.fontScale > 0.05) ? self.fontScale : 1.0;
    if (b.size.width < 40 || b.size.height < 40) return 60 * scale;
    CGFloat fs = MIN(b.size.height * 0.093, b.size.width * 0.060) * scale;
    return MAX(12, MIN(260, fs));
}

- (void)setFontScale:(CGFloat)fontScale {
    if (fabs(_fontScale - fontScale) < 0.001) return;
    _fontScale = fontScale;
    [_textH removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    NSColor *bgColor = [NSColor colorWithCalibratedWhite:0.075 alpha:1];
    [bgColor setFill];
    NSRectFill(b);

    NSArray<NMPLine *> *lines = self.lines;
    if (!lines.count) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:22 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.34 alpha:1]};
        NSString *hint = @"等待歌词…";
        NSSize sz = [hint sizeWithAttributes:attrs];
        [hint drawAtPoint:NSMakePoint((b.size.width - sz.width) / 2,
                                      (b.size.height - sz.height) / 2)
           withAttributes:attrs];
        return;
    }

    CGFloat fs = self.fontSize;
    CGFloat maxWidth = MAX(160, b.size.width - 72);
    if (!_textH) _textH = [NSMutableDictionary dictionary];
    if (fabs(fs - _cacheFS) > 0.4 || fabs(maxWidth - _cacheW) > 0.4) {
        [_textH removeAllObjects];
        _cacheFS = fs;
        _cacheW = maxWidth;
    }

    NSInteger count = (NSInteger)lines.count;
    NSInteger active = MIN(MAX(0, self.activeIndex), count - 1);
    BOOL started = !self.beforeStart;

    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.alignment = NSTextAlignmentCenter;
    para.lineBreakMode = NSLineBreakByWordWrapping;
    para.lineSpacing = fs * 0.16;   // 折行时行与行别贴在一起（英文尤其明显）

    // ── 布局：只量「还没量过的 (行号, 档位)」，其余走缓存 ──
    NSMutableArray<NSNumber *> *tops = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *slotHs = [NSMutableArray arrayWithCapacity:count];
    CGFloat total = 0, activeSlotH = 0, activeTextH = 0;
    for (NSInteger i = 0; i < count; i++) {
        NSInteger cls = MIN(4, (NSInteger)labs(i - active));
        CGFloat textH = [self textHeightAtIndex:i cls:cls fs:fs width:maxWidth para:para];
        CGFloat gap = fs * (cls == 0 ? 0.62 : 0.34);
        CGFloat slotH = textH + gap * 2;
        [tops addObject:@(total)];
        [slotHs addObject:@(slotH)];
        total += slotH;
        if (i == active) { activeSlotH = slotH; activeTextH = textH; }
    }

    // 当前行中心落在窗口 42% 高处，平滑跟随
    CGFloat target = [tops[active] doubleValue] + activeSlotH / 2 - b.size.height * 0.42;
    target = MIN(MAX(0, target), MAX(0, total - b.size.height));
    _scrollY += (target - _scrollY) * 0.22;
    if (!isfinite(_scrollY)) _scrollY = target;
    self.animating = fabs(target - _scrollY) > 0.4;

    // ── 绘制：屏幕外的行直接跳过（这是帧率提升的主要来源） ──
    for (NSInteger i = 0; i < count; i++) {
        CGFloat slotTop = [tops[i] doubleValue] - _scrollY;
        CGFloat slotH = [slotHs[i] doubleValue];
        if (slotTop + slotH < -20 || slotTop > b.size.height + 20) continue;

        BOOL isCurrent = (i == active) && started;
        CGFloat textH = slotH - fs * (i == active ? 1.24 : 0.68);
        CGFloat top = slotTop + (slotH - textH) / 2;

        if (isCurrent) {
            // 暗底（未唱色）+ 亮层按「字符位置」填充 —— 位置是小数，
            // 所以一个字还没唱完就能填一半，看起来才是卡拉 OK 那种推着走的光带。
            NSAttributedString *dim = [self currentLine:lines[i] fs:fs para:para bright:NO];
            [self drawText:dim width:maxWidth top:top prefix:NSUIntegerMax];

            NSAttributedString *bright = [self currentLine:lines[i] fs:fs para:para bright:YES];
            CGFloat cp = [self charPosForLine:lines[i]];
            if (cp > 0.02) [self drawKaraoke:bright width:maxWidth top:top charPos:cp];
        } else {
            NSInteger cls = MIN(4, (NSInteger)labs(i - active));
            NSFont *f = [NSFont systemFontOfSize:fs * NMPClassScale(cls)
                                          weight:(cls <= 1 ? NSFontWeightSemibold
                                                           : NSFontWeightRegular)];
            NSAttributedString *as = [[NSAttributedString alloc]
                initWithString:lines[i].text attributes:@{
                    NSFontAttributeName: f,
                    NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0
                                                                               alpha:NMPClassAlpha(cls)],
                    NSParagraphStyleAttributeName: para}];
            [self drawText:as width:maxWidth top:top prefix:NSUIntegerMax];
        }
    }

    // ── 上下渐隐（同色遮罩，渐变对象按高度缓存） ──
    CGFloat fade = MIN(100, b.size.height * 0.15);
    if (!_gTop || fabs(fade - _gHeight) > 0.5) {
        _gTop = [[NSGradient alloc] initWithStartingColor:[bgColor colorWithAlphaComponent:1]
                                              endingColor:[bgColor colorWithAlphaComponent:0]];
        _gBot = [[NSGradient alloc] initWithStartingColor:[bgColor colorWithAlphaComponent:0]
                                              endingColor:[bgColor colorWithAlphaComponent:1]];
        _gHeight = fade;
    }
    [_gTop drawInRect:NSMakeRect(0, 0, b.size.width, fade) angle:90];
    [_gBot drawInRect:NSMakeRect(0, b.size.height - fade, b.size.width, fade) angle:90];
}

// 文字高度缓存：同一行的同一个档位只量一次
- (CGFloat)textHeightAtIndex:(NSInteger)i cls:(NSInteger)cls fs:(CGFloat)fs
                       width:(CGFloat)maxWidth para:(NSParagraphStyle *)para {
    NSNumber *key = @(i * 8 + cls);
    NSNumber *hit = _textH[key];
    if (hit) return hit.doubleValue;
    NSFont *f = [NSFont systemFontOfSize:fs * NMPClassScale(cls)
                                  weight:(cls <= 1 ? NSFontWeightSemibold : NSFontWeightRegular)];
    NSAttributedString *probe = [[NSAttributedString alloc]
        initWithString:self.lines[i].text
            attributes:@{NSFontAttributeName: f, NSParagraphStyleAttributeName: para}];
    CGFloat h = [probe boundingRectWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin].size.height;
    h = MAX(h, fs * NMPClassScale(cls) * 1.18);
    _textH[key] = @(h);
    return h;
}

/// 当前句：只用两种颜色 —— 未唱 32% 白、扫光亮层纯白。
/// 唱到哪儿完全由遮罩决定（逐词着色会和扫光打架，反而看不出进度）。
- (NSAttributedString *)currentLine:(NMPLine *)line fs:(CGFloat)fs
                               para:(NSParagraphStyle *)para bright:(BOOL)bright {
    NSColor *color = bright ? [NSColor colorWithCalibratedWhite:1.0 alpha:1]
                            : [NSColor colorWithCalibratedWhite:0.32 alpha:1];
    return [[NSAttributedString alloc] initWithString:line.text attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:fs weight:NSFontWeightBold],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: para}];
}

/// 已经唱到「第几个字」—— 返回值带小数：3.4 表示第 3 个字唱了 40%。
/// 关键：旧版按整字取 prefix，单字词（中文几乎都是）在它被唱的整段时间里
/// 一个字都不会亮，看上去就是「亮的总是前一个字、最后一个字从不亮」。
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

/// 卡拉 OK 扫光：按行分段裁剪，行内裁剪点随「字符位置」连续移动。
/// 字符位置是小数，所以一个字能被填到一半 —— 这才是卡拉 OK 那条推着走的光带。
- (void)drawKaraoke:(NSAttributedString *)bright width:(CGFloat)maxWidth
                top:(CGFloat)top charPos:(CGFloat)charPos {
    NSUInteger len = bright.length;
    if (!len) return;

    NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:bright];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)];
    tc.lineFragmentPadding = 0;
    [tc setMaximumNumberOfLines:0];
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    [lm ensureLayoutForTextContainer:tc];

    CGFloat x0 = floor((self.bounds.size.width - maxWidth) / 2);
    CGFloat cp = MIN(MAX(0, charPos), (CGFloat)len);

    NSUInteger ci = MIN((NSUInteger)floor(cp), len - 1);
    CGFloat frac = (cp >= (CGFloat)len) ? 1.0 : (cp - floor(cp));
    NSUInteger gi = [lm glyphIndexForCharacterAtIndex:ci];
    NSRect gRect = [lm boundingRectForGlyphRange:NSMakeRange(gi, 1) inTextContainer:tc];
    CGFloat sweepX = gRect.origin.x + gRect.size.width * frac;

    NSUInteger g = 0, total = [lm numberOfGlyphs];
    while (g < total) {
        NSRange lr;
        NSRect fr = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:&lr];
        CGFloat left = fr.origin.x, right = fr.origin.x + fr.size.width;
        CGFloat endX = -1;
        BOOL partial = NO;
        if (NSMaxRange(lr) <= gi) {
            endX = right;                                   // 整行唱过
        } else if (lr.location <= gi && gi < NSMaxRange(lr)) {
            endX = MIN(right, MAX(left, sweepX));           // 正在唱的这一行
            partial = YES;
        } else {
            break;                                          // 后面的行不发光
        }

        if (endX > left + 0.5) {
            [NSGraphicsContext saveGraphicsState];
            NSRectClip(NSMakeRect(x0 + left, fr.origin.y + top, endX - left, fr.size.height + 2));
            [lm drawGlyphsForGlyphRange:lr atPoint:NSMakePoint(x0, top)];
            [NSGraphicsContext restoreGraphicsState];
        }

        g = NSMaxRange(lr);
    }
}

/// 用 NSLayoutManager 按「字形范围」绘制 —— 关键：多行时只画到第 N 个字符，
/// 不会像矩形裁剪那样把下面几行一起点亮。
- (void)drawText:(NSAttributedString *)as width:(CGFloat)maxWidth
             top:(CGFloat)top prefix:(NSUInteger)prefix {
    if (!as.length || !isfinite(top)) return;
    NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:as];
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)];
    tc.lineFragmentPadding = 0;
    [tc setMaximumNumberOfLines:0];
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    [lm ensureLayoutForTextContainer:tc];

    NSRange gr = NSMakeRange(0, ts.length);
    if (prefix < ts.length) {
        gr = [lm glyphRangeForCharacterRange:NSMakeRange(0, prefix) actualCharacterRange:NULL];
    }
    if (gr.length == 0) return;
    CGFloat x0 = floor((self.bounds.size.width - maxWidth) / 2);
    [lm drawGlyphsForGlyphRange:gr atPoint:NSMakePoint(x0, top)];
}

@end

// ================================================================ 拖放转发协议

// ================================================================ 控制器

@interface NMPLyricsController : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *lyricsWindow;   // 独立歌词窗（不吸附任何窗口）
@property (nonatomic, strong) NMPStageView *stage;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *renderTimer;
@property (nonatomic, strong) NSSlider *scaleSlider;
@property (nonatomic, strong) NSTextField *scaleLabel;

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

@property (nonatomic) AXUIElementRef appElement;
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
        AXUIElementSetMessagingTimeout(_appElement, 1.0);
        [self buildWindow];
        [self observeMenus];
        [self installLyricsHotkey];
        
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
                                                    selector:@selector(poll) userInfo:nil repeats:YES];
        // 60fps（扫光要顺），但 render 里会判断「真的有变化」才重绘
        _renderTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 target:self
                                             selector:@selector(render) userInfo:nil repeats:YES];
        _renderTimer.tolerance = 0.004;
        [[NSRunLoop mainRunLoop] addTimer:_renderTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}

// ---------------------------------------------------------------- 窗口

- (void)buildWindow {
    // 独立歌词窗：不绑任何窗口，拖到副屏投影、拉大缩小都随你。
    // 界面里没有设置条 —— 只留歌词本身，字号完全跟着窗口缩放。
    NSColor *bgBlack = [NSColor colorWithCalibratedWhite:0.045 alpha:1];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1000, 560)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                          | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    win.releasedWhenClosed = NO;   // 红钮只隐藏不销毁，否则 _lyricsWindow 变野指针
    win.title = @"歌词";
    win.delegate = self;
    win.minSize = NSMakeSize(360, 220);
    win.backgroundColor = bgBlack;
    win.titlebarAppearsTransparent = YES;
    win.titleVisibility = NSWindowTitleVisible;
    [win setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];

    NMPStageView *stage = [[NMPStageView alloc] initWithFrame:win.contentView.bounds];
    stage.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [win.contentView addSubview:stage];
    _stage = stage;

    // ── 字号滑条：右下角一小条，不占歌词布局（窗口缩放依然有效，这里调的是倍率）──
    CGFloat saved = [[NSUserDefaults standardUserDefaults] doubleForKey:kPrefFontScale];
    if (saved < 0.5 || saved > 2.1) saved = 1.0;

    NSSlider *sl = [NSSlider sliderWithValue:saved minValue:0.6 maxValue:2.0
                                      target:self action:@selector(fontScaleChanged:)];
    sl.frame = NSMakeRect(win.contentView.bounds.size.width - 168, 14, 140, 18);
    sl.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    sl.controlSize = NSControlSizeSmall;
    sl.alphaValue = 0.55;
    [win.contentView addSubview:sl];
    _scaleSlider = sl;

    NSTextField *scLab = [[NSTextField alloc] initWithFrame:
                          NSMakeRect(win.contentView.bounds.size.width - 206, 15, 34, 16)];
    scLab.editable = NO;
    scLab.bordered = NO;
    scLab.drawsBackground = NO;
    scLab.selectable = NO;
    scLab.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    scLab.textColor = [NSColor colorWithCalibratedWhite:0.62 alpha:1];
    scLab.alignment = NSTextAlignmentRight;
    scLab.stringValue = [NSString stringWithFormat:@"%.1f×", saved];
    scLab.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [win.contentView addSubview:scLab];
    _scaleLabel = scLab;

    stage.fontScale = saved;

    [win center];
    _lyricsWindow = win;
}

- (void)fontScaleChanged:(NSSlider *)sender {
    CGFloat v = sender.doubleValue;
    _stage.fontScale = v;
    _scaleLabel.stringValue = [NSString stringWithFormat:@"%.1f×", v];
    sender.alphaValue = 0.9;
    [[NSUserDefaults standardUserDefaults] setDouble:v forKey:kPrefFontScale];
    [_stage setNeedsDisplay:YES];
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
    for (NSWindow *w in [NSApp windows]) {
        if ([w.title isEqualToString:@"Neural Mix"] && w.isVisible) return w;
    }
    return nil;
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
    double fraction = 0;

    CFTypeRef windowsRef = NULL;
    if (AXUIElementCopyAttributeValue(_appElement, kAXWindowsAttribute, &windowsRef) != kAXErrorSuccess) return;
    CFArrayRef windows = (CFArrayRef)windowsRef;
    NSString *fallbackElapsed = @"", *fallbackRemaining = @"", *fallbackPlay = @"";
    double fallbackFraction = 0;
    BOOL gotTitle = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        NSString *t = @"", *a2 = @"", *el = @"", *rem = @"", *pb = @"";
        double fr = 0;
        [self walk:win depth:0 title:&t artist:&a2 elapsed:&el
         remaining:&rem playTitle:&pb fraction:&fr];
        // ① 优先采用「有曲名」的窗口，避免两个唱盘的 Elapsed time 互相覆盖导致来回跳
        if (t.length && !gotTitle) {
            title = t; artist = a2; elapsedText = el;
            remainingText = rem; playBtnTitle = pb; fraction = fr;
            gotTitle = YES;
        } else if (!gotTitle && !fallbackElapsed.length && el.length) {
            // ② 但万一 AX 暂时读不到曲名（换歌瞬间、标题元素未就绪），
            //    也必须继续用时间推进，否则位置彻底冻结 —— 就是「歌词卡住」。
            fallbackElapsed = el;
            fallbackRemaining = rem;
            fallbackPlay = pb;
            fallbackFraction = fr;
        }
    }
    if (!gotTitle && fallbackElapsed.length) {
        elapsedText = fallbackElapsed;
        remainingText = fallbackRemaining;
        playBtnTitle = fallbackPlay;
        fraction = fallbackFraction;
    }
    CFRelease(windowsRef);

    // 按钮要先于 title 检查：没歌时也要能呼出歌词窗
    [self ensureHostButton];

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
        _lines = nil;
        _lastLineIndex = -2;
        _boundTitle = nil;
        _retryCount = 0;
        _haveAnchor = NO;      // 新歌：重新锚定，别拿上一首的位置算
        _lastLockedE = -1;
        _playing = NO;
        [self resolveLyricsForTitle:title artist:artist];
    }

    // 主窗健康复位放在 10Hz 的 poll 里做就够了，别占 60fps 的渲染循环
    [self normalizeHostWindow:[self hostWindow]];
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
    void (^__block walk)(NSView *);
    walk = ^(NSView *v) {
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
        for (NSView *sub in v.subviews) walk(sub);
    };
    walk(theme);
    return best;
}

- (NSView *)titlebarContainerOf:(NSWindow *)w {
    NSView *theme = w.contentView.superview;
    if (!theme) return nil;
    __block NSView *found = nil;
    void (^__block walk)(NSView *);
    walk = ^(NSView *v) {
        if (found) return;
        if ([NSStringFromClass(v.class) containsString:@"TitlebarContainer"]) { found = v; return; }
        for (NSView *sub in v.subviews) walk(sub);
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
    if (!stack || !container) return;

    // 图标尺寸/颜色按邻居实测：字形 16×16pt、纯白（截图量得 32×32 px @2x）
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:15
                                                        weight:NSFontWeightMedium];
    NSImage *icon = [[NSImage imageWithSystemSymbolName:@"captions.bubble"
                                accessibilityDescription:@"歌词"]
                     imageWithSymbolConfiguration:cfg];
    icon.template = YES;
    NMPTitleButton *btn = [NMPTitleButton buttonWithImage:icon
                                                   target:self
                                                   action:@selector(toggleWindow:)];
    btn.bordered = NO;
    btn.imagePosition = NSImageOnly;
    btn.imageScaling = NSImageScaleProportionallyDown;
    btn.contentTintColor = [NSColor whiteColor];
    btn.toolTip = @"歌词";
    btn.wantsLayer = YES;
    btn.layer.cornerRadius = 6;
    // 邻居底色实测 RGB(51,52,53)；我们原来是 0.22 白（渲染成 72,72,72），偏亮
    btn.layer.backgroundColor =
        [NSColor colorWithSRGBRed:51/255.0 green:52/255.0 blue:53/255.0 alpha:1.0].CGColor;
    btn.autoresizingMask = 0;

    // 挂在 NSTitlebarContainerView（普通 NSView）而不是 NSStackView 里：
    // stack 只把事件转给它自己托管的 arrangedSubviews，塞普通子视图能看见但点不动。
    // 放到最上层，否则会被标题栏背景/工具栏盖住（看得见点不着）
    [container addSubview:btn positioned:NSWindowAbove relativeTo:nil];
    _lyricsButton = btn;
    [self syncLyricsButtonFrame];
}

// 几何照抄邻居：同一 y、同高、同宽，挂在最左那个按钮的左边 10pt
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
    NSRect target = NSMakeRect(inContainer.origin.x - 10 - inContainer.size.width,
                               inContainer.origin.y,
                               inContainer.size.width,
                               inContainer.size.height);
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
                double wEnd = (k + 1 < (NSInteger)line.words.count) ? line.words[k + 1].time
                              : ((i + 1 < (NSInteger)_lines.count) ? _lines[i + 1].time : wStart + 1.2);
                // 一句的最后一个词往往离下一句有间奏，按「到下一句」算会让这个字
                // 拖很久才亮完（看着像不亮）。词内进度最多拉 1.2 秒。
                if (wEnd - wStart > 1.2) wEnd = wStart + 1.2;
                prog = (wEnd > wStart) ? (t - wStart) / (wEnd - wStart) : 1.0;
            } else {
                double lEnd = (i + 1 < (NSInteger)_lines.count) ? _lines[i + 1].time : line.time + 4.0;
                prog = (lEnd > line.time) ? (t - line.time) / (lEnd - line.time) : 0;
            }
        }
    }

    // 只有真的变了才重绘 —— 这是「歌词窗帧率低」的另一半原因：
    // 原来每帧无条件 setNeedsDisplay，等于每秒 20 次全量重画。
    BOOL changed = (_stage.activeIndex != idx || _stage.activeWord != word ||
                    _stage.beforeStart != before ||
                    fabs(_stage.activeProgress - prog) > 0.002);
    _stage.activeIndex = idx;
    _stage.activeWord = word;
    _stage.activeProgress = prog;
    _stage.beforeStart = before;

    if (changed || _stage.animating) [_stage setNeedsDisplay:YES];
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

// 解析 ID3v2 标签，取歌词：USLT / SYLT / TXXX(lyrics) / v2.2 ULT
- (NSString *)extractLyricsTextFromFile:(NSURL *)url {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!fh) return nil;
    NSData *hdr = [fh readDataOfLength:10];
    if (hdr.length < 10 || memcmp(hdr.bytes, "ID3", 3) != 0) { [fh closeFile]; return nil; }
    const uint8_t *h = hdr.bytes;
    uint8_t ver = h[3];
    uint8_t flags = h[5];
    NSUInteger tagSize = ((NSUInteger)(h[6] & 0x7f) << 21) | ((NSUInteger)(h[7] & 0x7f) << 14)
                       | ((NSUInteger)(h[8] & 0x7f) << 7)  | (NSUInteger)(h[9] & 0x7f);
    if (tagSize == 0 || tagSize > 16 * 1024 * 1024) { [fh closeFile]; return nil; }
    // 读整段标签（旧代码只读 256KB，标签大就截断 → 歌词帧在尾部时永远找不到）
    NSMutableData *body = [[fh readDataOfLength:tagSize] mutableCopy];
    [fh closeFile];
    if (!body.length) return nil;

    // unsynchronisation：FF 00 → FF（老 MP3 常用，不做这步整段错位）
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
                // ⚠️ v2.4 帧长度是 syncsafe（每字节 7 位）；按普通整数读会错位，
                // 这是「部分文件识别不出歌词」的主因之一
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
        }
        pos += hdrLen + fsize;
    }
    return timestamped.length ? timestamped : plainLyrics;
}

// ---------------------------------------------------------------- 歌词定位（多路带超时）

- (void)resolveLyricsForTitle:(NSString *)title artist:(NSString *)artist {
    if (_matching) return;
    _matching = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *foundPath = nil;

        // ① 进程内钩子捕获的最近音频文件 —— NMP 刚刚打开的就是这首歌
        NSString *captured = LastAudioPath;
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

        // ② 本机快速查找（限时 3 秒）
        if (!foundPath) {
            foundPath = [self quickFind:title];
        }

        // ③ 用户指定文件夹扫描（限时 3 秒）
        if (!foundPath) {
            NSString *folder = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefFolder];
            if (!folder.length) folder = kDefaultFolder;
            foundPath = [self scanFolder:[folder stringByExpandingTildeInPath]
                                    title:title timeout:3.0];
        }

        // ⚠️ 读文件+解析必须留在后台：主线程读 iCloud 未物化文件会触发下载，
        // 把 UI 堵死几十秒（「开关歌词窗卡死」的元凶）。全部后台做完再回主线程。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *okPath = nil;
            if (foundPath && [self parseFileAtPath:foundPath]) {
                okPath = foundPath;
            } else if (captured.length && [self parseFileAtPath:captured]) {
                // 钩子抓到的就是 NMP 正在播的文件 —— 名字不匹配也直试
                okPath = captured;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                _matching = NO;
                if (okPath) {
                    [self commitParsedLines:[self pendingLines]
                                sourcePath:okPath];
                    return;
                }
                // 重试只试 captured（毫秒级），不再全量扫描 ——
                // 旧逻辑 4 轮全扫 ≈ 40 秒才见歌词，就是用户骂的「卡到 40 多秒」。
                if (_retryCount < 6 && _trackTitle.length && LastAudioPath.length) {
                    _retryCount++;
                    NSString *t = _trackTitle;
                    NSString *cap = LastAudioPath;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (!_lines.count && [_trackTitle isEqualToString:t]) {
                            [self retryCapturedPath:cap];
                        }
                    });
                    return;
                }
            });
        });
    });
}

// ---------------------------------------------------------------- 后台解析三件套
// parseFileAtPath（后台线程）：读文件+解析，结果暂存；
// commitParsedLines（主线程）：把暂存结果真正上屏。拆开是为了让 I/O 和解析
// 完全离开主线程 —— iCloud 未物化文件在主线程读会卡死 UI。

- (BOOL)parseFileAtPath:(NSString *)path {
    if (!path.length) return NO;
    _pendingLines = nil;
    _pendingOffset = 0;
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *text = nil;
    if ([ext isEqualToString:@"lrc"]) {
        text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text) {
            text = [NSString stringWithContentsOfFile:path
                encoding:(NSStringEncoding)CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)
                   error:nil];
        }
        if (text.length && [text characterAtIndex:0] == 0xFEFF) text = [text substringFromIndex:1];
    } else {
        text = [self extractLyricsTextFromFile:[NSURL fileURLWithPath:path]];
    }
    if (!text.length) return NO;
    NSArray<NMPLine *> *parsed = [self parseLyrics:text];
    if (!parsed.count) return NO;
    _pendingLines = parsed;
    return YES;
}

- (NSArray<NMPLine *> *)pendingLines { return _pendingLines; }

- (void)commitParsedLines:(NSArray<NMPLine *> *)lines sourcePath:(NSString *)path {
    if (!lines.count) return;
    _lines = lines;
    _lrcOffset = _pendingOffset;
    _lastLineIndex = -2;
    _boundTitle = _trackTitle;
}

// 轻重试（主线程入口，后台执行）：只试钩子抓到的文件，毫秒级，不做目录扫描
- (void)retryCapturedPath:(NSString *)cap {
    if (_matching) return;
    _matching = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [self parseFileAtPath:cap];
        NSArray<NMPLine *> *lines = ok ? [self pendingLines] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            _matching = NO;
            if (lines.count) {
                [self commitParsedLines:lines sourcePath:cap];
            } else if (_retryCount < 6 && _trackTitle.length && LastAudioPath.length) {
                _retryCount++;
                NSString *t = _trackTitle;
                NSString *c2 = LastAudioPath;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!_lines.count && [_trackTitle isEqualToString:t]) {
                        [self retryCapturedPath:c2];
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

/// 统一歌词解析 —— 网易云 / QQ音乐 / 酷我 / 酷狗 的内嵌歌词通吃：
///
///   行级 LRC：        [00:32.444]戏一折 水袖起落
///   词级 A2（网易云）： <02:50.610>真<02:50.950>的<02:51.390>希望
///   混合：            [00:32.4]<00:32.4>戏一折 <00:34.1>水袖起落
///   酷我头：          [kuwo:0141] [ver:v1.0] [ti:赤伶]  → 自动跳过
///
/// 同一行两种时间戳都有时，词级优先（逐字高亮靠它）。
- (NSArray<NMPLine *> *)parseLyrics:(NSString *)text {
    if (!text.length) return nil;
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
            stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    NSMutableArray<NMPLine *> *out = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;

        // [offset:+500]
        if ([line hasPrefix:@"[offset:"]) {
            NSRange close = [line rangeOfString:@"]"];
            if (close.location != NSNotFound) {
                double ms = [[line substringWithRange:NSMakeRange(8, close.location - 8)] doubleValue];
                _lrcOffset = ms / 1000.0;
            }
            continue;
        }

        // ① 行首 [mm:ss] 时间戳（可多个：[00:12][01:40]副歌）
        NSMutableArray<NSNumber *> *lineTimes = [NSMutableArray array];
        NSUInteger i = 0;
        while (i < line.length && [line characterAtIndex:i] == '[') {
            NSRange close = [line rangeOfString:@"]" options:0 range:NSMakeRange(i, line.length - i)];
            if (close.location == NSNotFound) break;
            double t = ParseClock([line substringWithRange:NSMakeRange(i + 1, close.location - i - 1)]);
            if (t < 0) break;   // [ti:xx] [kuwo:0141] 这类标签行
            [lineTimes addObject:@(t)];
            i = NSMaxRange(close);
        }
        NSString *body = [[line substringFromIndex:i] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (!body.length) continue;   // 纯标签行（[ti:xx] 等）

        // ② 行内 <mm:ss.mmm> 词级时间戳
        // ⚠️ 词的归属规则：**两个时间戳之间的字符属于前一个词**。
        // 之前按空格切段——中文没有空格，整句全堆在第一个词上，
        // 表现就是「逐字高亮失效、一整句同时变色」。
        NSMutableArray<NMPWord *> *words = [NSMutableArray array];
        NMPWord *current = nil;
        NSMutableString *headPlain = [NSMutableString string];   // 行首时间戳之前的裸文本
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
            // ⚠️ 不能逐个词 trim：英文歌词的空格就挂在词尾（"Beyond " + "the"），
            // 逐词裁掉会把所有英文粘成一串。只裁整行的首尾，词之间的空格原样保留。
            NSMutableString *raw = [headPlain mutableCopy];
            for (NMPWord *w in words) [raw appendString:w.text];

            NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
            NSInteger lead = 0, tail = (NSInteger)raw.length;
            while (lead < tail && [ws characterIsMember:[raw characterAtIndex:lead]]) lead++;
            while (tail > lead && [ws characterIsMember:[raw characterAtIndex:tail - 1]]) tail--;
            if (tail <= lead) continue;
            NSRange keep = NSMakeRange(lead, tail - lead);

            // 把每个词的取字范围收进 keep 区间，保证「词拼起来 == 行文本」，扫光才对得齐
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
            l.time = words.firstObject.time + _lrcOffset;
            l.text = trimmed;
            l.words = words;
            [out addObject:l];
        } else if (lineTimes.count) {
            NSString *lineText = [headPlain stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!lineText.length) continue;
            for (NSNumber *t in lineTimes) {
                NMPLine *l = [NMPLine new];
                l.time = MAX(0, t.doubleValue + _lrcOffset);
                l.text = lineText;
                l.words = nil;
                [out addObject:l];
            }
        }
    }
    if (!out.count) return nil;
    [out sortUsingComparator:^NSComparisonResult(NMPLine *a, NMPLine *b) {
        return (a.time == b.time) ? NSOrderedSame
             : ((a.time < b.time) ? NSOrderedAscending : NSOrderedDescending);
    }];
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

    // 文件捕获钩子（在任何 UI 之前）
    g_rebindings = NULL;
    struct rebinding_entry r1 = {"open",      (void *)hooked_open,      (void **)&orig_open};
    struct rebinding_entry r2 = {"openat",    (void *)hooked_openat,    (void **)&orig_openat};
    struct rebinding_entry r3 = {"fopen",     (void *)hooked_fopen,     (void **)&orig_fopen};
    r1.next = &r2; r2.next = &r3; r3.next = NULL;
    g_rebindings = &r1;
    rebind_symbols();

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationDidFinishLaunchingNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
                        [NMPLyricsController shared];
                    }];
    });
}
