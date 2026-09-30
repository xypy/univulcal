#import "DirectUVCBackend.h"
#import "libusb.h"
#import <ImageIO/ImageIO.h>
#include <libuvc/libuvc.h>
#include <string.h>

// Exported by the bundled libuvc, although omitted from its public header.
extern uvc_error_t uvc_query_stream_ctrl(uvc_device_handle_t *devh,
                                         uvc_stream_ctrl_t *ctrl, uint8_t probe,
                                         enum uvc_req_code req);

typedef struct {
    enum uvc_frame_format format;
    int width;
    int height;
    int fps;
} MNUVCMode;

static void MNAppendMode(MNUVCMode *modes, NSUInteger *count, NSUInteger capacity,
                         enum uvc_frame_format format, int width, int height, int fps) {
    if (width <= 0 || height <= 0 || fps <= 0 || *count >= capacity) return;
    for (NSUInteger index = 0; index < *count; index++) {
        if (modes[index].format == format && modes[index].width == width &&
            modes[index].height == height && modes[index].fps == fps) return;
    }
    modes[(*count)++] = (MNUVCMode){format, width, height, fps};
}

@interface MNDirectUVCBackend () {
    uvc_context_t *_context;
    uvc_device_t *_device;
    uvc_device_handle_t *_handle;
    uvc_stream_handle_t *_rawStream;
    uvc_stream_ctrl_t _streamControl;
    dispatch_queue_t _queue;
    dispatch_queue_t _readQueue;
    BOOL _running;
    BOOL _rawBulk;
    struct libusb_transfer *_bulkTransfer;
    uint8_t *_bulkBuffer;
    dispatch_group_t _bulkTransferGroup;
    uint8_t *_jpegBuffer;
    NSUInteger _jpegLength;
    BOOL _collectingJPEG;
    uint8_t _previousJPEGByte;
    NSUInteger _bulkChunkCount;
    NSUInteger _oversizedJPEGCount;
    uint64_t _frameCount;
    BOOL _savedJPEGFrame;
}
- (void)startHagibisBulkWithWidth:(int)width height:(int)height fps:(int)fps;
- (void)parseHagibisBulkChunk:(NSData *)chunk;
- (void)deliverJPEG:(const uint8_t *)bytes length:(NSUInteger)length;
@end

static void MNUVCFrameCallback(uvc_frame_t *frame, void *userPointer);
static void LIBUSB_CALL MNHagibisBulkCallback(struct libusb_transfer *transfer);

@implementation MNDirectUVCBackend

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.monicon.direct-uvc", DISPATCH_QUEUE_SERIAL);
        _readQueue = dispatch_queue_create("com.monicon.direct-uvc.bulk", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startWithWidth:(NSUInteger)width height:(NSUInteger)height fps:(NSUInteger)fps {
    dispatch_async(_queue, ^{
        __atomic_store_n(&self->_frameCount, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&self->_savedJPEGFrame, NO, __ATOMIC_RELAXED);
        uvc_error_t result = uvc_init(&self->_context, NULL);
        if (result < 0) {
            [self fail:[NSString stringWithFormat:@"uvc_init failed: %s (%d)", uvc_strerror(result), result]];
            return;
        }

        result = uvc_find_device(self->_context, &self->_device, 0, 0, NULL);
        if (result < 0) {
            [self fail:[NSString stringWithFormat:@"uvc_find_device failed: %s (%d)", uvc_strerror(result), result]];
            return;
        }

        uvc_device_descriptor_t *deviceDescriptor = NULL;
        BOOL isHagibis = NO;
        if (uvc_get_device_descriptor(self->_device, &deviceDescriptor) == UVC_SUCCESS && deviceDescriptor) {
            isHagibis = deviceDescriptor->idVendor == 0x1de1 && deviceDescriptor->idProduct == 0xf104;
            [self note:[NSString stringWithFormat:@"device vid=%04x pid=%04x product=%s",
                        deviceDescriptor->idVendor, deviceDescriptor->idProduct,
                        deviceDescriptor->product ?: "(unknown)"]];
            uvc_free_device_descriptor(deviceDescriptor);
        }

        result = uvc_open(self->_device, &self->_handle);
        if (result < 0) {
            [self fail:[NSString stringWithFormat:@"uvc_open failed: %s (%d)", uvc_strerror(result), result]];
            return;
        }

        int requestedWidth = (int)width;
        int requestedHeight = (int)height;
        int requestedFPS = fps == 0 ? 60 : (int)fps;
        const uvc_format_desc_t *format = uvc_get_format_descs(self->_handle);
        NSUInteger loggedFrames = 0;
        for (const uvc_format_desc_t *candidateFormat = format;
             candidateFormat && loggedFrames < 48; candidateFormat = candidateFormat->next) {
            for (const uvc_frame_desc_t *frame = candidateFormat->frame_descs;
                 frame && loggedFrames < 48; frame = frame->next, loggedFrames++) {
                NSMutableString *rates = [NSMutableString string];
                if (frame->intervals) {
                    for (NSUInteger index = 0; frame->intervals[index] && index < 8; index++) {
                        [rates appendFormat:@" %.2f", 10000000.0 / frame->intervals[index]];
                    }
                }
                [self note:[NSString stringWithFormat:
                            @"descriptor format=%u subtype=%u frame=%u %ux%u default=%.2f fps=%@",
                            candidateFormat->bFormatIndex, candidateFormat->bDescriptorSubtype,
                            frame->bFrameIndex, frame->wWidth, frame->wHeight,
                            frame->dwDefaultFrameInterval ? 10000000.0 / frame->dwDefaultFrameInterval : 0.0,
                            rates]];
            }
        }
        if (requestedWidth == 0 || requestedHeight == 0) {
            while (format && !format->frame_descs) { format = format->next; }
            if (format && format->frame_descs) {
                requestedWidth = (int)format->frame_descs->wWidth;
                requestedHeight = (int)format->frame_descs->wHeight;
            }
        }

        MNUVCMode modes[24];
        NSUInteger modeCount = 0;
#define ADD_PAIR(W, H, FPS) \
    MNAppendMode(modes, &modeCount, 24, UVC_FRAME_FORMAT_MJPEG, (W), (H), (FPS)); \
    MNAppendMode(modes, &modeCount, 24, UVC_FRAME_FORMAT_YUYV, (W), (H), (FPS))
        ADD_PAIR(requestedWidth, requestedHeight, requestedFPS);
        ADD_PAIR(1920, 1080, requestedFPS);
        ADD_PAIR(1280, 720, requestedFPS);
        ADD_PAIR(1920, 1080, 30);
        ADD_PAIR(1280, 720, 30);
        ADD_PAIR(640, 480, 30);
        ADD_PAIR(1920, 1080, 15);
        ADD_PAIR(1280, 720, 15);
        ADD_PAIR(640, 480, 15);
#undef ADD_PAIR

        result = UVC_ERROR_INVALID_MODE;
        for (NSUInteger index = 0; index < modeCount; index++) {
            MNUVCMode mode = modes[index];
            memset(&self->_streamControl, 0, sizeof(self->_streamControl));
            result = uvc_get_stream_ctrl_format_size(self->_handle, &self->_streamControl,
                                                      mode.format, mode.width, mode.height, mode.fps);
            [self note:[NSString stringWithFormat:
                        @"attempt %lu %@ %dx%d@%d result=%s (%d) control format=%u frame=%u interval=%u frameBytes=%u payloadBytes=%u",
                        (unsigned long)(index + 1),
                        mode.format == UVC_FRAME_FORMAT_MJPEG ? @"MJPEG" : @"YUYV",
                        mode.width, mode.height, mode.fps, uvc_strerror(result), result,
                        self->_streamControl.bFormatIndex, self->_streamControl.bFrameIndex,
                        self->_streamControl.dwFrameInterval,
                        self->_streamControl.dwMaxVideoFrameSize,
                        self->_streamControl.dwMaxPayloadTransferSize]];
            if (result == UVC_ERROR_INVALID_MODE && isHagibis && mode.format == UVC_FRAME_FORMAT_MJPEG) {
                uvc_stream_ctrl_t current = self->_streamControl;
                uvc_error_t queryResult = uvc_query_stream_ctrl(self->_handle, &current, 1, UVC_GET_CUR);
                BOOL matchingDescriptor = NO;
                for (const uvc_format_desc_t *candidate = format; candidate; candidate = candidate->next) {
                    if (candidate->bDescriptorSubtype != UVC_VS_FORMAT_MJPEG ||
                        candidate->bFormatIndex != current.bFormatIndex) continue;
                    for (const uvc_frame_desc_t *frame = candidate->frame_descs; frame; frame = frame->next) {
                        if (frame->bFrameIndex != current.bFrameIndex ||
                            frame->wWidth != mode.width || frame->wHeight != mode.height) continue;
                        for (NSUInteger interval = 0; frame->intervals && frame->intervals[interval]; interval++) {
                            if (frame->intervals[interval] == current.dwFrameInterval) matchingDescriptor = YES;
                        }
                    }
                }
                [self note:[NSString stringWithFormat:
                            @"Hagibis GET_CUR result=%s (%d) format=%u frame=%u interval=%u frameBytes=%u payloadBytes=%u descriptorMatch=%@",
                            uvc_strerror(queryResult), queryResult, current.bFormatIndex, current.bFrameIndex,
                            current.dwFrameInterval, current.dwMaxVideoFrameSize,
                            current.dwMaxPayloadTransferSize, matchingDescriptor ? @"YES" : @"NO"]];
                if (queryResult == UVC_SUCCESS && matchingDescriptor &&
                    current.dwMaxVideoFrameSize > 0 && current.dwMaxPayloadTransferSize > 0) {
                    self->_streamControl = current;
                    result = UVC_SUCCESS;
                    [self note:@"accepted camera's valid GET_CUR control; bundled libuvc rejects changed payload size"];
                }
            }
            if (result == UVC_SUCCESS) {
                requestedWidth = mode.width;
                requestedHeight = mode.height;
                requestedFPS = mode.fps;
                break;
            }
        }
        if (result < 0) {
            [self fail:[NSString stringWithFormat:@"UVC negotiation failed after %lu attempts: %s (%d); see monicon.log",
                        (unsigned long)modeCount, uvc_strerror(result), result]];
            return;
        }

        if (isHagibis) {
            // Keep the device's UVC control intact. A smaller value here made
            // libuvc misparse a large payload as several independent ones.
            [self startHagibisBulkWithWidth:requestedWidth height:requestedHeight fps:requestedFPS];
            return;
        }

        result = uvc_start_streaming(self->_handle, &self->_streamControl, MNUVCFrameCallback, (__bridge void *)self, 0);
        if (result < 0) {
            [self fail:[NSString stringWithFormat:@"uvc_start_streaming failed: %s (%d)", uvc_strerror(result), result]];
            return;
        }

        self->_running = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self->_running && __atomic_load_n(&self->_frameCount, __ATOMIC_RELAXED) == 0) {
                [self note:@"stream opened but no complete UVC frame arrived within 5 seconds"];
            }
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate uvcBackendDidStartWithWidth:(NSUInteger)requestedWidth height:(NSUInteger)requestedHeight fps:(NSUInteger)requestedFPS];
        });
    });
}

- (void)startHagibisBulkWithWidth:(int)width height:(int)height fps:(int)fps {
    uvc_error_t result = uvc_stream_open_ctrl(_handle, &_rawStream, &_streamControl);
    if (result != UVC_SUCCESS) {
        [self fail:[NSString stringWithFormat:@"Hagibis bulk open failed: %s (%d)", uvc_strerror(result), result]];
        return;
    }

    struct libusb_device_handle *usb = uvc_get_libusb_handle(_handle);
    struct libusb_config_descriptor *config = NULL;
    int usbResult = libusb_get_active_config_descriptor(libusb_get_device(usb), &config);
    uint8_t endpoint = 0;
    if (usbResult == LIBUSB_SUCCESS && config) {
        for (int i = 0; i < config->bNumInterfaces && !endpoint; i++) {
            const struct libusb_interface *interface = &config->interface[i];
            for (int a = 0; a < interface->num_altsetting && !endpoint; a++) {
                const struct libusb_interface_descriptor *alt = &interface->altsetting[a];
                if (alt->bInterfaceNumber != _streamControl.bInterfaceNumber) continue;
                for (int e = 0; e < alt->bNumEndpoints; e++) {
                    const struct libusb_endpoint_descriptor *candidate = &alt->endpoint[e];
                    if ((candidate->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) == LIBUSB_TRANSFER_TYPE_BULK &&
                        (candidate->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
                        endpoint = candidate->bEndpointAddress;
                        break;
                    }
                }
            }
        }
        libusb_free_config_descriptor(config);
    }
    if (!endpoint) {
        [self fail:[NSString stringWithFormat:@"Hagibis bulk endpoint not found: %s (%d)",
                    libusb_error_name(usbResult), usbResult]];
        return;
    }

    _jpegBuffer = malloc(4 * 1024 * 1024);
    _bulkBuffer = malloc(65536);
    _bulkTransfer = libusb_alloc_transfer(0);
    if (!_jpegBuffer || !_bulkBuffer || !_bulkTransfer) {
        [self fail:@"Hagibis bulk transfer allocation failed"];
        return;
    }
    _jpegLength = 0;
    _collectingJPEG = NO;
    _previousJPEGByte = 0;
    _bulkChunkCount = 0;
    _oversizedJPEGCount = 0;
    _bulkTransferGroup = dispatch_group_create();
    libusb_fill_bulk_transfer(_bulkTransfer, usb, endpoint, _bulkBuffer, 65536,
                              MNHagibisBulkCallback, (__bridge void *)self, 5000);
    __atomic_store_n(&_running, YES, __ATOMIC_RELEASE);
    dispatch_group_enter(_bulkTransferGroup);
    usbResult = libusb_submit_transfer(_bulkTransfer);
    if (usbResult != LIBUSB_SUCCESS) {
        dispatch_group_leave(_bulkTransferGroup);
        __atomic_store_n(&_running, NO, __ATOMIC_RELEASE);
        [self fail:[NSString stringWithFormat:@"Hagibis async bulk submit failed: %s (%d)",
                    libusb_error_name(usbResult), usbResult]];
        return;
    }
    _rawBulk = YES;
    [self note:[NSString stringWithFormat:@"Hagibis async bulk reader endpoint=0x%02x readBytes=65536 devicePayload=%u",
                endpoint, _streamControl.dwMaxPayloadTransferSize]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate uvcBackendDidStartWithWidth:(NSUInteger)width height:(NSUInteger)height fps:(NSUInteger)fps];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (__atomic_load_n(&self->_running, __ATOMIC_ACQUIRE) &&
            __atomic_load_n(&self->_frameCount, __ATOMIC_RELAXED) == 0) {
            [self note:@"raw bulk reader received no complete JPEG within 5 seconds"];
        }
    });
}

- (void)parseHagibisBulkChunk:(NSData *)chunk {
    const uint8_t *bytes = chunk.bytes;
    NSUInteger length = chunk.length;
    if (++_bulkChunkCount <= 3) {
        [self note:[NSString stringWithFormat:@"async bulk chunk %lu bytes=%lu first=%02x %02x %02x %02x",
                    (unsigned long)_bulkChunkCount, (unsigned long)length,
                    bytes[0], length > 1 ? bytes[1] : 0,
                    length > 2 ? bytes[2] : 0, length > 3 ? bytes[3] : 0]];
    }
    for (NSUInteger i = 0; i < length; i++) {
        uint8_t value = bytes[i];
        if (!_collectingJPEG) {
            if (_previousJPEGByte == 0xff && value == 0xd8) {
                _jpegBuffer[0] = 0xff;
                _jpegBuffer[1] = 0xd8;
                _jpegLength = 2;
                _collectingJPEG = YES;
            }
        } else if (_jpegLength >= 4 * 1024 * 1024) {
            _collectingJPEG = NO;
            _jpegLength = 0;
            if (_oversizedJPEGCount++ < 3) [self note:@"raw JPEG exceeded 4 MB; discarded"];
        } else {
            _jpegBuffer[_jpegLength++] = value;
            if (_previousJPEGByte == 0xff && value == 0xd9) {
                [self deliverJPEG:_jpegBuffer length:_jpegLength];
                _collectingJPEG = NO;
                _jpegLength = 0;
            }
        }
        _previousJPEGByte = value;
    }
}

static void LIBUSB_CALL MNHagibisBulkCallback(struct libusb_transfer *transfer) {
    MNDirectUVCBackend *backend = (__bridge MNDirectUVCBackend *)transfer->user_data;
    BOOL running = __atomic_load_n(&backend->_running, __ATOMIC_ACQUIRE);
    if (running && transfer->status == LIBUSB_TRANSFER_COMPLETED && transfer->actual_length > 0) {
        NSData *chunk = [NSData dataWithBytes:transfer->buffer length:(NSUInteger)transfer->actual_length];
        dispatch_async(backend->_readQueue, ^{ [backend parseHagibisBulkChunk:chunk]; });
    }
    if (running && (transfer->status == LIBUSB_TRANSFER_COMPLETED ||
                    transfer->status == LIBUSB_TRANSFER_TIMED_OUT)) {
        int result = libusb_submit_transfer(transfer);
        if (result == LIBUSB_SUCCESS) return;
        [backend note:[NSString stringWithFormat:@"async bulk resubmit error=%s (%d)",
                       libusb_error_name(result), result]];
    } else if (running) {
        [backend note:[NSString stringWithFormat:@"async bulk transfer status=%d bytes=%d",
                       transfer->status, transfer->actual_length]];
    }
    dispatch_group_leave(backend->_bulkTransferGroup);
}

- (void)deliverJPEG:(const uint8_t *)bytes length:(NSUInteger)length {
    if (length < 256) return;
    NSData *jpeg = [NSData dataWithBytes:bytes length:length];
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (!source) return;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSUInteger width = [properties[(NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    if (width == 0 || height == 0 || width > 3840 || height > 2160) {
        CFRelease(source);
        return;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return;
    NSUInteger count = __atomic_add_fetch(&_frameCount, 1, __ATOMIC_RELAXED);
    if (count <= 3) {
        [self note:[NSString stringWithFormat:@"raw JPEG frame %lu size=%lux%lu bytes=%lu",
                    (unsigned long)count, (unsigned long)width, (unsigned long)height, (unsigned long)length]];
    }
    if (!__atomic_exchange_n(&_savedJPEGFrame, YES, __ATOMIC_RELAXED)) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [documents stringByAppendingPathComponent:@"first-uvc-frame.jpg"];
        BOOL saved = [jpeg writeToFile:path atomically:YES];
        [self note:[NSString stringWithFormat:@"first raw JPEG saved=%@ path=%@",
                    saved ? @"YES" : @"NO", path]];
    }

    NSUInteger rgbaBytes = width * height * 4;
    uint8_t *rgba = malloc(rgbaBytes);
    uint8_t *rgb = malloc(width * height * 3);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = rgba ? CGBitmapContextCreate(rgba, width, height, 8, width * 4,
                                      colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    if (context && rgb) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        for (NSUInteger pixel = 0; pixel < width * height; pixel++) {
            rgb[pixel * 3] = rgba[pixel * 4];
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1];
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2];
        }
        NSData *data = [NSData dataWithBytesNoCopy:rgb length:width * height * 3 freeWhenDone:YES];
        rgb = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate uvcBackendDidReceiveRGB:data width:width height:height];
        });
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    CGImageRelease(image);
    free(rgba);
    free(rgb);
}

- (void)note:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate uvcBackendDidLog:message];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        __atomic_store_n(&self->_running, NO, __ATOMIC_RELEASE);
        if (self->_rawBulk) {
            int cancelResult = libusb_cancel_transfer(self->_bulkTransfer);
            if (cancelResult != LIBUSB_SUCCESS && cancelResult != LIBUSB_ERROR_NOT_FOUND) {
                [self note:[NSString stringWithFormat:@"async bulk cancel error=%s (%d)",
                            libusb_error_name(cancelResult), cancelResult]];
            }
            dispatch_group_wait(self->_bulkTransferGroup, DISPATCH_TIME_FOREVER);
            dispatch_sync(self->_readQueue, ^{});
            self->_rawBulk = NO;
        } else if (self->_handle && !self->_rawStream) {
            uvc_stop_streaming(self->_handle);
        }
        if (self->_bulkTransfer) {
            libusb_free_transfer(self->_bulkTransfer);
            self->_bulkTransfer = NULL;
        }
        free(self->_bulkBuffer);
        self->_bulkBuffer = NULL;
        free(self->_jpegBuffer);
        self->_jpegBuffer = NULL;
        if (self->_rawStream) {
            uvc_stream_close(self->_rawStream);
            self->_rawStream = NULL;
        }
        if (self->_handle) {
            uvc_close(self->_handle);
            self->_handle = NULL;
        }
        if (self->_device) {
            uvc_unref_device(self->_device);
            self->_device = NULL;
        }
        if (self->_context) {
            uvc_exit(self->_context);
            self->_context = NULL;
        }
    });
}

- (void)fail:(NSString *)message {
    [self stop];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate uvcBackendDidFail:message];
    });
}

static void MNUVCFrameCallback(uvc_frame_t *frame, void *userPointer) {
    MNDirectUVCBackend *backend = (__bridge MNDirectUVCBackend *)userPointer;
    if (!backend->_running || !frame) return;

    uint64_t count = __atomic_add_fetch(&backend->_frameCount, 1, __ATOMIC_RELAXED);
    const uint8_t *bytes = frame->data;
    BOOL jpeg = frame->data_bytes >= 4 && bytes && bytes[0] == 0xff && bytes[1] == 0xd8;
    if (jpeg && !__atomic_exchange_n(&backend->_savedJPEGFrame, YES, __ATOMIC_RELAXED)) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                    NSUserDomainMask, YES).firstObject;
        NSString *path = [documents stringByAppendingPathComponent:@"first-uvc-frame.jpg"];
        BOOL saved = [[NSData dataWithBytes:bytes length:frame->data_bytes] writeToFile:path atomically:YES];
        [backend note:[NSString stringWithFormat:@"first valid MJPEG frame saved=%@ sequence=%u bytes=%zu path=%@",
                       saved ? @"YES" : @"NO", frame->sequence, frame->data_bytes, path]];
    }
    if (count <= 3) {
        [backend note:[NSString stringWithFormat:
                       @"frame %llu format=%d size=%ux%u bytes=%zu sequence=%u jpegSOI=%@",
                       (unsigned long long)count, frame->frame_format, frame->width, frame->height,
                       frame->data_bytes, frame->sequence, jpeg ? @"YES" : @"NO"]];
    }

    uvc_frame_t *rgb = uvc_allocate_frame(frame->width * frame->height * 3);
    if (!rgb) {
        if (count <= 3) [backend note:@"RGB frame allocation failed"];
        return;
    }

    uvc_error_t result = uvc_any2rgb(frame, rgb);
    if (count <= 3) {
        [backend note:[NSString stringWithFormat:@"frame %llu RGB conversion=%s (%d) outputBytes=%zu",
                       (unsigned long long)count, uvc_strerror(result), result, rgb->data_bytes]];
    }
    if (result == UVC_SUCCESS) {
        const NSUInteger outputWidth = frame->width;
        const NSUInteger outputHeight = frame->height;
        const NSUInteger outputBytes = rgb->data_bytes;
        NSData *data = [NSData dataWithBytes:rgb->data length:outputBytes];
        dispatch_async(dispatch_get_main_queue(), ^{
            [backend.delegate uvcBackendDidReceiveRGB:data width:outputWidth height:outputHeight];
        });
    }
    uvc_free_frame(rgb);
}

@end
