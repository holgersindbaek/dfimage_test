// The MIT License (MIT)
//
// Copyright (c) 2015 Alexander Grebenyuk (github.com/kean).
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "DFCachedImageResponse.h"
#import "DFImageCaching.h"
#import "DFImageDecoder.h"
#import "DFImageDecoding.h"
#import "DFImageFetching.h"
#import "DFImageManagerConfiguration.h"
#import "DFImageManagerDefines.h"
#import "DFImageManagerImageLoader.h"
#import "DFImageProcessing.h"
#import "DFImageRequest.h"
#import "DFImageRequestOptions.h"
#import "DFImageTask.h"
#import "DFProgressiveImageDecoder.h"

#pragma mark - _DFImageLoaderTask

@class _DFImageLoadOperation;

@interface _DFImageLoaderTask : NSObject

@property (nonnull, nonatomic, readonly) DFImageTask *imageTask;
@property (nonnull, nonatomic, readonly) DFImageRequest *request; // dynamic
@property (nullable, nonatomic, weak) _DFImageLoadOperation *loadOperation;
@property (nullable, nonatomic, weak) NSOperation *processOperation;

@end

@implementation _DFImageLoaderTask

- (nonnull instancetype)initWithImageTask:(nonnull DFImageTask *)imageTask {
    if (self = [super init]) {
        _imageTask = imageTask;
    }
    return self;
}

- (DFImageRequest * __nonnull)request {
    return self.imageTask.request;
}

@end


#pragma mark - _DFImageRequestKey

@class _DFImageRequestKey;

@protocol _DFImageRequestKeyOwner <NSObject>

- (BOOL)isImageRequestKey:(nonnull _DFImageRequestKey *)lhs equalToKey:(nonnull _DFImageRequestKey *)rhs;

@end

/*! Make it possible to use DFImageRequest as a key in dictionaries (and dictionary-like structures). Requests may be interpreted differently so we compare them using <DFImageFetching> -isRequestFetchEquivalent:toRequest: method and (optionally) similar <DFImageProcessing> method.
 */
@interface _DFImageRequestKey : NSObject <NSCopying>

@property (nonnull, nonatomic, readonly) DFImageRequest *request;
@property (nonatomic, readonly) BOOL isCacheKey;
@property (nullable, nonatomic, weak, readonly) id<_DFImageRequestKeyOwner> owner;

@end

@implementation _DFImageRequestKey {
    NSUInteger _hash;
}

- (nonnull instancetype)initWithRequest:(nonnull DFImageRequest *)request isCacheKey:(BOOL)isCacheKey owner:(nonnull id<_DFImageRequestKeyOwner>)owner {
    if (self = [super init]) {
        _request = request;
        _hash = [request.resource hash];
        _isCacheKey = isCacheKey;
        _owner = owner;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (NSUInteger)hash {
    return _hash;
}

- (BOOL)isEqual:(_DFImageRequestKey *)other {
    if (other == self) {
        return YES;
    }
    if (other.owner != _owner) {
        return NO;
    }
    return [_owner isImageRequestKey:self equalToKey:other];
}

@end


#pragma mark - _DFImageLoadOperation

@interface _DFImageLoadOperation : NSObject

@property (nonnull, nonatomic, readonly) _DFImageRequestKey *key;
@property (nullable, nonatomic) NSOperation *operation;
@property (nonnull, nonatomic, readonly) NSMutableArray *tasks;
@property (nonatomic) int64_t totalUnitCount;
@property (nonatomic) int64_t completedUnitCount;
@property (nonatomic) DFProgressiveImageDecoder *progressiveImageDecoder;

@end

@implementation _DFImageLoadOperation

- (nonnull instancetype)initWithKey:(nonnull _DFImageRequestKey *)key {
    if (self = [super init]) {
        _key = key;
        _tasks = [NSMutableArray new];
    }
    return self;
}

- (void)updateOperationPriority {
    if (_operation && _tasks.count) {
        DFImageRequestPriority priority = DFImageRequestPriorityVeryLow;
        for (_DFImageLoaderTask *task in _tasks) {
            priority = MAX(task.imageTask.priority, priority);
        }
        if (_operation.queuePriority != (NSOperationQueuePriority)priority) {
            _operation.queuePriority = (NSOperationQueuePriority)priority;
        }
    }
}

@end


#pragma mark - DFImageManagerImageLoader

#define DFImageCacheKeyCreate(request) [[_DFImageRequestKey alloc] initWithRequest:request isCacheKey:YES owner:self]
#define DFImageLoadKeyCreate(request) [[_DFImageRequestKey alloc] initWithRequest:request isCacheKey:NO owner:self]

@interface DFImageManagerImageLoader () <_DFImageRequestKeyOwner>

@property (nonnull, nonatomic, readonly) DFImageManagerConfiguration *conf;
@property (nonnull, nonatomic, readonly) NSMutableDictionary /* DFImageTask : _DFImageLoaderTask */ *executingTasks;
@property (nonnull, nonatomic, readonly) NSMutableDictionary /* _DFImageRequestKey : _DFImageLoadOperation */ *loadOperations;
@property (nonnull, nonatomic, readonly) dispatch_queue_t queue;
@property (nonnull, nonatomic, readonly) NSOperationQueue *decodingQueue;
@property (nonatomic, readonly) BOOL fetcherRespondsToCanonicalRequest;

@end

@implementation DFImageManagerImageLoader

- (nonnull instancetype)initWithConfiguration:(nonnull DFImageManagerConfiguration *)configuration {
    if (self = [super init]) {
        NSParameterAssert(configuration);
        _conf = [configuration copy];
        _executingTasks = [NSMutableDictionary new];
        _loadOperations = [NSMutableDictionary new];
        _queue = dispatch_queue_create([[NSString stringWithFormat:@"%@-queue-%p", [self class], self] UTF8String], DISPATCH_QUEUE_SERIAL);
        _decodingQueue = [NSOperationQueue new];
        _decodingQueue.maxConcurrentOperationCount = 1; // Serial queue
        _fetcherRespondsToCanonicalRequest = [_conf.fetcher respondsToSelector:@selector(canonicalRequestForRequest:)];
    }
    return self;
}

- (void)startLoadingForImageTask:(nonnull DFImageTask *)imageTask {
    _DFImageLoaderTask *loaderTask = [[_DFImageLoaderTask alloc] initWithImageTask:imageTask];
    _executingTasks[imageTask] = loaderTask;
    dispatch_async(_queue, ^{
        [self _startLoadOperationForTask:loaderTask];
    });
}

- (void)_startLoadOperationForTask:(_DFImageLoaderTask *)task {
    _DFImageRequestKey *key = DFImageLoadKeyCreate(task.request);
    _DFImageLoadOperation *operation = _loadOperations[key];
    if (!operation) {
        operation = [[_DFImageLoadOperation alloc] initWithKey:key];
        BlockWeakSelf weakSelf = self;
        operation.operation = [_conf.fetcher startOperationWithRequest:task.request progressHandler:^(NSData *__nullable data, int64_t completedUnitCount, int64_t totalUnitCount) {
            [weakSelf _loadOperation:operation didUpdateProgressWithData:data completedUnitCount:completedUnitCount totalUnitCount:totalUnitCount];
        } completion:^(NSData *__nullable data, NSDictionary *__nullable info, NSError *__nullable error) {
            [weakSelf _loadOperation:operation didCompleteWithData:data info:info error:error];
        }];
        _loadOperations[key] = operation;
    } else {
        [self.delegate imageLoader:self imageTask:task.imageTask didUpdateProgressWithCompletedUnitCount:operation.completedUnitCount totalUnitCount:operation.totalUnitCount];
    }
    task.loadOperation = operation;
    [operation.tasks addObject:task];
    [operation updateOperationPriority];
}

- (void)_loadOperation:(nonnull _DFImageLoadOperation *)operation didUpdateProgressWithData:(NSData *__nullable)data completedUnitCount:(int64_t)completedUnitCount totalUnitCount:(int64_t)totalUnitCount {
    dispatch_async(_queue, ^{
        // update progress
        operation.totalUnitCount = totalUnitCount;
        operation.completedUnitCount = completedUnitCount;
        for (_DFImageLoaderTask *task in operation.tasks) {
            [self.delegate imageLoader:self imageTask:task.imageTask didUpdateProgressWithCompletedUnitCount:operation.completedUnitCount totalUnitCount:operation.totalUnitCount];
        }
        // progressive image decoding
        if (!_conf.allowsProgressiveImage) {
            return;
        }
        if (completedUnitCount >= totalUnitCount) {
            [operation.progressiveImageDecoder invalidate];
            return;
        }
        DFProgressiveImageDecoder *decoder = operation.progressiveImageDecoder;
        if (!decoder) {
            decoder = [[DFProgressiveImageDecoder alloc] initWithQueue:_decodingQueue decoder:_conf.decoder ?: [DFImageDecoder sharedDecoder]];
            decoder.threshold = _conf.progressiveImageDecodingThreshold;
            decoder.totalByteCount = totalUnitCount;
            BlockWeakSelf weakSelf = self;
            _DFImageLoadOperation *__weak weakOp = operation;
            decoder.handler = ^(UIImage *__nonnull image) {
                [weakSelf _loadOperation:weakOp didDecodePartialImage:image];
            };
            operation.progressiveImageDecoder = decoder;
        }
        [decoder appendData:data];
        for (_DFImageLoaderTask *task in operation.tasks) {
            if (task.imageTask.progressiveImageHandler && task.request.options.allowsProgressiveImage) {
                [decoder resume];
                break;
            }
        }
    });
}

- (void)_loadOperation:(nonnull _DFImageLoadOperation *)operation didDecodePartialImage:(nonnull UIImage *)image {
    dispatch_async(_queue, ^{
        for (_DFImageLoaderTask *task in operation.tasks) {
            if ([self _shouldProcessImage:image forRequest:task.request partial:YES]) {
                BlockWeakSelf weakSelf = self;
                id<DFImageProcessing> processor = _conf.processor;
                [_conf.processingQueue addOperationWithBlock:^{
                    UIImage *processedImage = [processor processedImage:image forRequest:task.request partial:YES];
                    if (processedImage) {
                        [weakSelf.delegate imageLoader:weakSelf imageTask:task.imageTask didReceiveProgressiveImage:processedImage];
                    }
                }];
            } else {
                [self.delegate imageLoader:self imageTask:task.imageTask didReceiveProgressiveImage:image];
            }
        }
    });
}

- (void)_loadOperation:(nonnull _DFImageLoadOperation *)operation didCompleteWithData:(nullable NSData *)data info:(nullable NSDictionary *)info error:(nullable NSError *)error {
    if (data.length) {
        BlockWeakSelf weakSelf = self;
        [_decodingQueue addOperationWithBlock:^{
            id<DFImageDecoding> decoder = weakSelf.conf.decoder ?: [DFImageDecoder sharedDecoder];
            UIImage *image = [decoder imageWithData:data partial:NO];
            [weakSelf _loadOperation:operation didCompleteWithImage:image info:info error:error];
        }];
    } else {
        [self _loadOperation:operation didCompleteWithImage:nil info:info error:error];
    }
}

- (void)_loadOperation:(nonnull _DFImageLoadOperation *)operation didCompleteWithImage:(nullable UIImage *)image info:(nullable NSDictionary *)info error:(nullable NSError *)error {
    dispatch_async(_queue, ^{
        for (_DFImageLoaderTask *task in operation.tasks) {
            [self _loadTask:task processImage:image info:info error:error];
        }
        [operation.tasks removeAllObjects];
        [_loadOperations removeObjectForKey:operation.key];
    });
}

- (void)_loadTask:(nonnull _DFImageLoaderTask *)task processImage:(nullable UIImage *)image info:(nullable NSDictionary *)info error:(nullable NSError *)error {
    if (image && [self _shouldProcessImage:image forRequest:task.request partial:NO]) {
        BlockWeakSelf weakSelf = self;
        id<DFImageProcessing> processor = _conf.processor;
        NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
            UIImage *processedImage = [weakSelf cachedResponseForRequest:task.request].image;
            if (!processedImage) {
                processedImage = [processor processedImage:image forRequest:task.request partial:NO];
                [weakSelf _storeImage:processedImage info:info forRequest:task.request];
            }
            [weakSelf _loadTask:task didCompleteWithImage:processedImage info:info error:error];
        }];
        [_conf.processingQueue addOperation:operation];
        task.processOperation = operation;
    } else {
        [self _storeImage:image info:info forRequest:task.request];
        [self _loadTask:task didCompleteWithImage:image info:info error:error];
    }
}

- (void)_loadTask:(nonnull _DFImageLoaderTask *)task didCompleteWithImage:(nullable UIImage *)image info:(nullable NSDictionary *)info error:(nullable NSError *)error {
    dispatch_async(_queue, ^{
        [self.delegate imageLoader:self imageTask:task.imageTask didCompleteWithImage:image info:info error:error];
        [_executingTasks removeObjectForKey:task.imageTask];
    });
}

- (void)cancelLoadingForImageTask:(nonnull DFImageTask *)imageTask {
    dispatch_async(_queue, ^{
        _DFImageLoaderTask *loaderTask = _executingTasks[imageTask];
        _DFImageLoadOperation *operation = loaderTask.loadOperation;
        if (operation) {
            [operation.tasks removeObject:loaderTask];
            if (operation.tasks.count == 0) {
                [operation.operation cancel];
                [_loadOperations removeObjectForKey:operation.key];
            } else {
                [operation updateOperationPriority];
            }
        }
        [loaderTask.processOperation cancel];
        [_executingTasks removeObjectForKey:imageTask];
    });
}

- (void)updateLoadingPriorityForImageTask:(nonnull DFImageTask *)imageTask {
    dispatch_async(_queue, ^{
        _DFImageLoaderTask *loaderTask = _executingTasks[imageTask];
        [loaderTask.loadOperation updateOperationPriority];
    });
}

#pragma mark Processing

- (BOOL)_shouldProcessImage:(nonnull UIImage *)image forRequest:(nonnull DFImageRequest *)request partial:(BOOL)partial {
    if (!_conf.processor || !_conf.processingQueue) {
        return NO;
    }
    return [_conf.processor shouldProcessImage:image forRequest:request partial:partial];
}

#pragma mark Caching

- (nullable DFCachedImageResponse *)cachedResponseForRequest:(nonnull DFImageRequest *)request {
    return request.options.memoryCachePolicy != DFImageRequestCachePolicyReloadIgnoringCache ? [_conf.cache cachedImageResponseForKey:DFImageCacheKeyCreate(request)] : nil;
}

- (void)_storeImage:(nullable UIImage *)image info:(nullable NSDictionary *)info forRequest:(nonnull DFImageRequest *)request {
    if (image) {
        DFCachedImageResponse *cachedResponse = [[DFCachedImageResponse alloc] initWithImage:image info:info expirationDate:(CACurrentMediaTime() + request.options.expirationAge)];
        [_conf.cache storeImageResponse:cachedResponse forKey:DFImageCacheKeyCreate(request)];
    }
}

#pragma mark Misc

- (nonnull DFImageRequest *)canonicalRequestForRequest:(nonnull DFImageRequest *)request {
    return _fetcherRespondsToCanonicalRequest ? [_conf.fetcher canonicalRequestForRequest:request] : request;
}

- (nonnull NSArray *)canonicalRequestsForRequests:(nonnull NSArray *)requests {
    if (!_fetcherRespondsToCanonicalRequest) {
        return requests;
    }
    NSMutableArray *canonicalRequests = [[NSMutableArray alloc] initWithCapacity:requests.count];
    for (DFImageRequest *request in requests) {
        [canonicalRequests addObject:[self canonicalRequestForRequest:request]];
    }
    return canonicalRequests;
}

- (nonnull id<NSCopying>)processingKeyForRequest:(nonnull DFImageRequest *)request {
    return DFImageCacheKeyCreate(request);
}

#pragma mark <_DFImageRequestKeyOwner>

- (BOOL)isImageRequestKey:(nonnull _DFImageRequestKey *)lhs equalToKey:(nonnull _DFImageRequestKey *)rhs {
    if (lhs.isCacheKey) {
        if (![_conf.fetcher isRequestCacheEquivalent:lhs.request toRequest:rhs.request]) {
            return NO;
        }
        return _conf.processor ? [_conf.processor isProcessingForRequestEquivalent:lhs.request toRequest:rhs.request] : YES;
    } else {
        return [_conf.fetcher isRequestFetchEquivalent:lhs.request toRequest:rhs.request];
    }
}

@end
