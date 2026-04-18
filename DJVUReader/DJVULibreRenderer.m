#import "DJVULibreRenderer.h"

#include <libdjvu/ddjvuapi.h>

static NSString * const DJVULibreRendererErrorDomain = @"DJVULibreRendererErrorDomain";

@interface DJVULibreRenderer () {
    ddjvu_context_t *_context;
    ddjvu_document_t *_document;
    ddjvu_format_t *_pixelFormat;
    NSMutableDictionary<NSNumber *, NSValue *> *_pageHandles;
    NSMutableDictionary<NSNumber *, NSValue *> *_pageSizes;
}

@property (nonatomic, readwrite) NSInteger pageCount;
@property (nonatomic, readwrite) NSDictionary<NSNumber *, NSNumber *> *pageAspectRatios;

- (BOOL)bitmapLooksSuspiciouslyBlank:(NSBitmapImageRep *)bitmap;

@end

@implementation DJVULibreRenderer

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError * _Nullable __autoreleasing *)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    _pageHandles = [NSMutableDictionary dictionary];
    _pageSizes = [NSMutableDictionary dictionary];
    _pageAspectRatios = @{};
    _context = ddjvu_context_create("DJVUReader");
    if (!_context) {
        [self populateError:error description:@"Не удалось создать context libdjvu"];
        return nil;
    }

    ddjvu_cache_set_size(_context, 256UL * 1024UL * 1024UL);

    _document = ddjvu_document_create_by_filename_utf8(_context, url.path.UTF8String, TRUE);
    if (!_document) {
        [self populateError:error description:@"Не удалось открыть DJVU документ через libdjvu"];
        [self invalidateRenderer];
        return nil;
    }

    _pixelFormat = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, NULL);
    if (!_pixelFormat) {
        [self populateError:error description:@"Не удалось создать формат пикселей libdjvu"];
        [self invalidateRenderer];
        return nil;
    }

    ddjvu_format_set_row_order(_pixelFormat, TRUE);
    ddjvu_format_set_y_direction(_pixelFormat, TRUE);

    if (![self waitForDocumentReady:error]) {
        [self invalidateRenderer];
        return nil;
    }

    _pageCount = ddjvu_document_get_pagenum(_document);
    _pageAspectRatios = [self buildPageAspectRatios];
    return self;
}

- (void)dealloc {
    [self invalidateRenderer];
}

- (nullable NSImage *)renderPageAtIndex:(NSInteger)pageIndex
                              pixelSize:(CGSize)pixelSize
                              isPreview:(BOOL)isPreview
                                  error:(NSError * _Nullable __autoreleasing *)error {
    if (pageIndex < 0 || pageIndex >= self.pageCount) {
        [self populateError:error description:@"Некорректный индекс страницы DJVU"];
        return nil;
    }

    ddjvu_page_t *page = [self pageHandleForIndex:pageIndex];
    if (!page) {
        [self populateError:error description:@"Не удалось создать объект страницы libdjvu"];
        return nil;
    }

    if (![self waitForPageDecoded:page error:error]) {
        return nil;
    }

    NSInteger pixelWidth = MAX(1, (NSInteger)lrint(pixelSize.width));
    NSInteger pixelHeight = MAX(1, (NSInteger)lrint(pixelSize.height));

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:pixelWidth
                      pixelsHigh:pixelHeight
                   bitsPerSample:8
                 samplesPerPixel:3
                        hasAlpha:NO
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:0
                     bytesPerRow:pixelWidth * 3
                    bitsPerPixel:24];

    if (!bitmap || !bitmap.bitmapData) {
        [self populateError:error description:@"Не удалось выделить буфер для рендера DJVU страницы"];
        return nil;
    }

    memset(bitmap.bitmapData, 0xFF, (size_t)bitmap.bytesPerRow * (size_t)pixelHeight);

    ddjvu_rect_t pageRect = {0, 0, (unsigned int)pixelWidth, (unsigned int)pixelHeight};
    ddjvu_rect_t renderRect = pageRect;

    int rendered = ddjvu_page_render(
        page,
        DDJVU_RENDER_COLOR,
        &pageRect,
        &renderRect,
        _pixelFormat,
        (unsigned long)bitmap.bytesPerRow,
        (char *)bitmap.bitmapData
    );

    if (!rendered) {
        if (![self waitForPageDecoded:page error:error]) {
            return nil;
        }

        rendered = ddjvu_page_render(
            page,
            DDJVU_RENDER_COLOR,
            &pageRect,
            &renderRect,
            _pixelFormat,
            (unsigned long)bitmap.bytesPerRow,
            (char *)bitmap.bitmapData
        );
    }

    if (!rendered) {
        [self populateError:error description:@"libdjvu не смог отрендерить страницу"];
        return nil;
    }

    if ([self bitmapLooksSuspiciouslyBlank:bitmap]) {
        [self populateError:error description:@"libdjvu вернул пустой bitmap для страницы"];
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(pixelWidth, pixelHeight)];
    [image addRepresentation:bitmap];
    return image;
}

- (CGSize)pageSizeAtIndex:(NSInteger)pageIndex {
    NSValue *cachedValue = _pageSizes[@(pageIndex)];
    if (cachedValue) {
        return cachedValue.sizeValue;
    }

    ddjvu_pageinfo_t info;
    ddjvu_status_t status = ddjvu_document_get_pageinfo(_document, (int)pageIndex, &info);
    while (status < DDJVU_JOB_OK) {
        if (![self pumpMessagesWaiting:YES]) {
            return CGSizeZero;
        }
        status = ddjvu_document_get_pageinfo(_document, (int)pageIndex, &info);
    }

    if (status >= DDJVU_JOB_OK && info.width > 0 && info.height > 0) {
        CGSize pageSize = CGSizeMake(info.width, info.height);
        _pageSizes[@(pageIndex)] = [NSValue valueWithSize:pageSize];
        return pageSize;
    }

    return CGSizeZero;
}

- (void)invalidateRenderer {
    for (NSNumber *pageIndex in _pageHandles) {
        ddjvu_page_t *page = _pageHandles[pageIndex].pointerValue;
        if (page) {
            ddjvu_page_release(page);
        }
    }
    [_pageHandles removeAllObjects];

    if (_pixelFormat) {
        ddjvu_format_release(_pixelFormat);
        _pixelFormat = NULL;
    }

    if (_document) {
        ddjvu_document_release(_document);
        _document = NULL;
    }

    if (_context) {
        ddjvu_context_release(_context);
        _context = NULL;
    }
}

- (BOOL)waitForDocumentReady:(NSError * _Nullable __autoreleasing *)error {
    while (!ddjvu_document_decoding_done(_document)) {
        if (![self pumpMessagesWaiting:YES error:error]) {
            return NO;
        }
    }

    if (ddjvu_document_decoding_error(_document)) {
        [self populateError:error description:@"libdjvu не смог декодировать документ"];
        return NO;
    }

    return YES;
}

- (BOOL)waitForPageDecoded:(ddjvu_page_t *)page error:(NSError * _Nullable __autoreleasing *)error {
    while (!ddjvu_page_decoding_done(page)) {
        if (![self pumpMessagesWaiting:YES error:error]) {
            return NO;
        }
    }

    if (ddjvu_page_decoding_error(page)) {
        [self populateError:error description:@"libdjvu не смог декодировать страницу"];
        return NO;
    }

    return YES;
}

- (ddjvu_page_t *)pageHandleForIndex:(NSInteger)pageIndex {
    NSNumber *key = @(pageIndex);
    NSValue *cachedValue = _pageHandles[key];
    if (cachedValue) {
        return cachedValue.pointerValue;
    }

    ddjvu_page_t *page = ddjvu_page_create_by_pageno(_document, (int)pageIndex);
    if (page) {
        _pageHandles[key] = [NSValue valueWithPointer:page];
    }
    return page;
}

- (NSDictionary<NSNumber *, NSNumber *> *)buildPageAspectRatios {
    NSMutableDictionary<NSNumber *, NSNumber *> *ratios = [NSMutableDictionary dictionaryWithCapacity:self.pageCount];

    for (NSInteger pageIndex = 0; pageIndex < self.pageCount; pageIndex++) {
        ddjvu_pageinfo_t info;
        ddjvu_status_t status = ddjvu_document_get_pageinfo(_document, (int)pageIndex, &info);

        while (status < DDJVU_JOB_OK) {
            if (![self pumpMessagesWaiting:YES]) {
                break;
            }
            status = ddjvu_document_get_pageinfo(_document, (int)pageIndex, &info);
        }

        if (status >= DDJVU_JOB_OK && info.width > 0 && info.height > 0) {
            _pageSizes[@(pageIndex)] = [NSValue valueWithSize:CGSizeMake(info.width, info.height)];
            ratios[@(pageIndex)] = @((double)info.height / (double)info.width);
        }
    }

    return ratios;
}

- (BOOL)pumpMessagesWaiting:(BOOL)shouldWait {
    return [self pumpMessagesWaiting:shouldWait error:nil];
}

- (BOOL)pumpMessagesWaiting:(BOOL)shouldWait error:(NSError * _Nullable __autoreleasing *)error {
    if (shouldWait) {
        ddjvu_message_wait(_context);
    }

    const ddjvu_message_t *message = NULL;
    while ((message = ddjvu_message_peek(_context))) {
        if (message->m_any.tag == DDJVU_ERROR) {
            const char *rawMessage = message->m_error.message ?: "libdjvu unknown error";
            NSString *description = [NSString stringWithUTF8String:rawMessage] ?: @"libdjvu unknown error";
            ddjvu_message_pop(_context);
            [self populateError:error description:description];
            return NO;
        }

        ddjvu_message_pop(_context);
    }

    return YES;
}

- (void)populateError:(NSError * _Nullable __autoreleasing *)error description:(NSString *)description {
    if (!error) {
        return;
    }

    *error = [NSError errorWithDomain:DJVULibreRendererErrorDomain
                                 code:1
                             userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (BOOL)bitmapLooksSuspiciouslyBlank:(NSBitmapImageRep *)bitmap {
    unsigned char *data = bitmap.bitmapData;
    if (!data) {
        return YES;
    }

    const NSInteger width = bitmap.pixelsWide;
    const NSInteger height = bitmap.pixelsHigh;
    const NSInteger bytesPerRow = bitmap.bytesPerRow;
    if (width <= 0 || height <= 0 || bytesPerRow <= 0) {
        return YES;
    }

    const NSInteger sampleColumns = MIN(48, MAX(8, width / 32));
    const NSInteger sampleRows = MIN(48, MAX(8, height / 32));
    NSInteger nonWhiteSamples = 0;
    NSInteger totalSamples = 0;

    for (NSInteger row = 0; row < sampleRows; row++) {
        NSInteger y = (row * (height - 1)) / MAX(sampleRows - 1, 1);
        unsigned char *rowData = data + y * bytesPerRow;

        for (NSInteger column = 0; column < sampleColumns; column++) {
            NSInteger x = (column * (width - 1)) / MAX(sampleColumns - 1, 1);
            unsigned char *pixel = rowData + x * 3;
            totalSamples += 1;

            if (pixel[0] < 245 || pixel[1] < 245 || pixel[2] < 245) {
                nonWhiteSamples += 1;
            }
        }
    }

    if (totalSamples == 0) {
        return YES;
    }

    double nonWhiteRatio = (double)nonWhiteSamples / (double)totalSamples;
    return nonWhiteRatio < 0.002;
}

@end
