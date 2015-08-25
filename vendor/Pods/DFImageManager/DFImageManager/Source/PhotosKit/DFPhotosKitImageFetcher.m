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

#import "DFImageRequest.h"
#import "DFImageRequestOptions.h"
#import "DFPhotosKitImageFetcher.h"
#import "NSURL+DFPhotosKit.h"
#import <Photos/Photos.h>


NS_CLASS_AVAILABLE_IOS(8_0) @interface _DFPhotosKitImageFetchOperation : NSOperation

@property (nonatomic, readonly) NSData *result;
@property (nonatomic, readonly) NSDictionary *info;

- (instancetype)initWithResource:(id)resource options:(PHImageRequestOptions *)options NS_DESIGNATED_INITIALIZER;

@end


NSString *const DFPhotosKitVersionKey = @"DFPhotosKitVersionKey";

typedef struct {
    PHImageRequestOptionsVersion version;
} _DFPhotosKitRequestOptions;

static inline NSString *_PHAssetLocalIdentifier(id resource) {
    if ([resource isKindOfClass:[PHAsset class]]) {
        return ((PHAsset *)resource).localIdentifier;
    } else {
        return [((NSURL *)resource) df_assetLocalIdentifier];
    }
}

@implementation DFPhotosKitImageFetcher {
    NSOperationQueue *_queue;
}

- (instancetype)init {
    if (self = [super init]) {
        _queue = [NSOperationQueue new];
        _queue.maxConcurrentOperationCount = 2;
    }
    return self;
}

#pragma mark - <DFImageFetching>

- (BOOL)canHandleRequest:(DFImageRequest *)request {
    id asset = request.resource;
    if ([asset isKindOfClass:[PHAsset class]]) {
        return YES;
    }
    if ([asset isKindOfClass:[NSURL class]]) {
        if ([((NSURL *)asset).scheme isEqualToString:DFPhotosKitURLScheme]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)isRequestFetchEquivalent:(DFImageRequest *)request1 toRequest:(DFImageRequest *)request2 {
    if (![self isRequestCacheEquivalent:request1 toRequest:request2]) {
        return NO;
    }
    return (request1.options.allowsNetworkAccess == request2.options.allowsNetworkAccess);
}

- (BOOL)isRequestCacheEquivalent:(DFImageRequest *)request1 toRequest:(DFImageRequest *)request2 {
    if (request1 == request2) {
        return YES;
    }
    if ([request1.resource isKindOfClass:[PHAsset class]] &&
        [request2.resource isKindOfClass:[PHAsset class]]) {
        // Comparing PHAsset's directly is much faster then getting their localIdentifiers.
        if (![request1.resource isEqual:request2.resource]) {
            return NO;
        }
    } else if (![_PHAssetLocalIdentifier(request1.resource) isEqualToString:_PHAssetLocalIdentifier(request2.resource)]) {
        return NO;
    }
    if (!(CGSizeEqualToSize(request1.targetSize, request2.targetSize) &&
          request1.contentMode == request2.contentMode)) {
        return NO;
    }
    _DFPhotosKitRequestOptions options1 = [self _requestOptionsFromUserInfo:request1.options.userInfo];
    _DFPhotosKitRequestOptions options2 = [self _requestOptionsFromUserInfo:request2.options.userInfo];
    return (options1.version == options2.version);
}

- (nonnull NSOperation *)startOperationWithRequest:(nonnull DFImageRequest *)request progressHandler:(nullable DFImageFetchingProgressHandler)progressHandler completion:(nullable DFImageFetchingCompletionHandler)completion {
    _DFPhotosKitRequestOptions options = [self _requestOptionsFromUserInfo:request.options.userInfo];
    PHImageRequestOptions *requestOptions = [PHImageRequestOptions new];
    requestOptions.networkAccessAllowed = request.options.allowsNetworkAccess;
    requestOptions.version = options.version;
    requestOptions.progressHandler = ^(double progress, NSError *error, BOOL *stop, NSDictionary *info){
        if (progressHandler) {
            int64_t totalUnitCount = 1000;
            progressHandler(nil, (int64_t)progress * totalUnitCount, totalUnitCount);
        }
    };

    id resource = request.resource;
    if ([resource isKindOfClass:[NSURL class]]) {
        resource = [((NSURL *)resource) df_assetLocalIdentifier];
    }

    _DFPhotosKitImageFetchOperation *operation = [[_DFPhotosKitImageFetchOperation alloc] initWithResource:resource options:requestOptions];
    _DFPhotosKitImageFetchOperation *__weak weakOp = operation;
    operation.completionBlock = ^{
        if (completion) {
            completion(weakOp.result, weakOp.info, nil);
        }
    };
    [_queue addOperation:operation];
    return operation;
}

- (_DFPhotosKitRequestOptions)_requestOptionsFromUserInfo:(NSDictionary *)info {
    _DFPhotosKitRequestOptions options;
    NSNumber *version = info[DFPhotosKitVersionKey];
    options.version = version ? version.integerValue : PHImageRequestOptionsVersionCurrent;
    return options;
}

@end


@interface _DFPhotosKitImageFetchOperation ()

@property (nonatomic, getter = isExecuting) BOOL executing;
@property (nonatomic, getter = isFinished) BOOL finished;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithResource:(id)resource options:(PHImageRequestOptions *)options NS_DESIGNATED_INITIALIZER;

@end

@implementation _DFPhotosKitImageFetchOperation {
    PHAsset *_asset;
    NSString *_localIdentifier;
    PHImageRequestOptions *_options;
    PHImageRequestID _requestID;
}

@synthesize executing = _executing;
@synthesize finished = _finished;

DF_INIT_UNAVAILABLE_IMPL

- (instancetype)initWithResource:(id)resource options:(PHImageRequestOptions *)options {
    if (self = [super init]) {
        if ([resource isKindOfClass:[PHAsset class]]) {
            _asset = (PHAsset *)resource;
        } else if ([resource isKindOfClass:[NSString class]]) {
            _localIdentifier = (NSString *)resource;
        }
        _options = options;
        _requestID = PHInvalidImageRequestID;
    }
    return self;
}

- (void)start {
    @synchronized(self) {
        self.executing = YES;
        if (self.isCancelled) {
            [self finish];
        } else {
            [self _fetch];
        }
    }
}

- (void)finish {
    if (_executing) {
        self.executing = NO;
    }
    self.finished = YES;
}

- (void)_fetch {
    if (!_asset && _localIdentifier) {
        if (_localIdentifier) {
            _asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[_localIdentifier] options:nil].firstObject;
        }
    }
    if (!self.isCancelled) {
        BlockWeakSelf weakSelf = self;
        _requestID = [[PHImageManager defaultManager] requestImageDataForAsset:_asset options:_options resultHandler:^(NSData *imageData, NSString *dataUTI, UIImageOrientation orientation, NSDictionary *info) {
            [weakSelf _didFetchImageData:imageData info:info];
        }];
    } else {
        [self finish];
    }
}

- (void)_didFetchImageData:(NSData *)result info:(NSDictionary *)info {
    @synchronized(self) {
        if (!self.isCancelled) {
            _result = result;
            _info = info;
            [self finish];
        }
    }
}

- (void)cancel {
    @synchronized(self) {
        if (!self.isCancelled && !self.isFinished) {
            [super cancel];
            if (_requestID != PHInvalidImageRequestID) {
                /*! From Apple docs: "If the request is cancelled, resultHandler may not be called at all.", that's why all the mess.
                 */
                [[PHImageManager defaultManager] cancelImageRequest:_requestID];
                [self finish];
            }
        }
    }
}

- (void)setFinished:(BOOL)finished {
    [self willChangeValueForKey:@"isFinished"];
    _finished = finished;
    [self didChangeValueForKey:@"isFinished"];
}

- (void)setExecuting:(BOOL)executing {
    [self willChangeValueForKey:@"isExecuting"];
    _executing = executing;
    [self didChangeValueForKey:@"isExecuting"];
}

@end
