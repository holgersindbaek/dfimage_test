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

#import "DFCompositeImageTask.h"
#import "DFImageManager.h"
#import "DFImageRequest.h"
#import "DFImageTask.h"

@implementation DFCompositeImageTask {
    BOOL _isStarted;
    NSMutableArray *_remainingTasks;
}

DF_INIT_UNAVAILABLE_IMPL

- (nonnull instancetype)initWithImageTasks:(nonnull NSArray *)tasks imageHandler:(nullable DFCompositeImageTaskImageHandler)imageHandler completionHandler:(nullable DFCompositeImageTaskCompletionHandler)completionHandler {
    if (self = [super init]) {
        NSParameterAssert(tasks.count > 0);
        _imageTasks = [tasks copy];
        _remainingTasks = [NSMutableArray arrayWithArray:tasks];
        _imageHandler = imageHandler;
        _completionHandler = completionHandler;
        _allowsObsoleteRequests = YES;
    }
    return self;
}

+ (nullable DFCompositeImageTask *)compositeImageTaskWithRequests:(nonnull NSArray *)requests imageHandler:(nullable DFCompositeImageTaskImageHandler)imageHandler completionHandler:(nullable DFCompositeImageTaskCompletionHandler)completionHandler {
    NSParameterAssert(requests.count > 0);
    NSMutableArray *tasks = [NSMutableArray new];
    for (DFImageRequest *request in requests) {
        DFImageTask *task = [[DFImageManager sharedManager] imageTaskForRequest:request completion:nil];
        if (task) {
            [tasks addObject:task];
        }
    }
    return tasks.count ? [[[self class] alloc] initWithImageTasks:tasks imageHandler:imageHandler completionHandler:completionHandler] : nil;
}

- (void)resume {
    if (_isStarted) {
        return;
    }
    _isStarted = YES;
    BlockWeakSelf weakSelf = self;
    for (DFImageTask *task in _remainingTasks) {
        DFImageTaskCompletion completionHandler = task.completionHandler;
        task.completionHandler = ^(UIImage *__nullable image, NSError *__nullable error, DFImageResponse *__nullable response, DFImageTask *__nonnull completedTask) {
            [weakSelf _didFinishImageTask:completedTask withImage:image];
            if (completionHandler) {
                completionHandler(image, error, response, completedTask);
            }
        };
    }
    for (DFImageTask *task in [_remainingTasks copy]) {
        [task resume];
    }
}

- (BOOL)isFinished {
    return _remainingTasks.count == 0;
}

- (void)cancel {
    _imageHandler = nil;
    _completionHandler = nil;
    for (DFImageTask *task in [_remainingTasks copy]) {
        [self _cancelTask:task];
    }
}

- (void)setPriority:(DFImageRequestPriority)priority {
    for (DFImageTask *task in _remainingTasks) {
        task.priority = priority;
    }
}

- (void)_didFinishImageTask:(nonnull DFImageTask *)task withImage:(nullable UIImage *)image {
    if (![_remainingTasks containsObject:task]) {
        return;
    }
    if (self.allowsObsoleteRequests) {
        BOOL isSuccess = [self _isTaskSuccessfull:task];
        BOOL isObsolete = [self _isTaskObsolete:task];
        if (isSuccess) {
            // Iterate through the 'left' subarray and cancel obsolete requests
            NSArray *obsoleteTasks = [_remainingTasks objectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [_remainingTasks indexOfObject:task])]];
            for (DFImageTask *obsoleteTask in obsoleteTasks) {
                [self _cancelTask:obsoleteTask];
            }
        }
        [_remainingTasks removeObject:task];
        if (isSuccess && !isObsolete) {
            if (_imageHandler) {
                _imageHandler(image, task, self);
            }
        }
    } else {
        [_remainingTasks removeObject:task];
        if (_imageHandler) {
            _imageHandler(image, task, self);
        }
    }
    if (self.isFinished) {
        if (_completionHandler) {
            _completionHandler(self);
        }
    }
}

- (void)_cancelTask:(nonnull DFImageTask *)task {
    [_remainingTasks removeObject:task];
    [task cancel];
}

- (BOOL)_isTaskSuccessfull:(nonnull DFImageTask *)task {
    return task.state == DFImageTaskStateCompleted && task.error == nil;

}

/*! Returns YES if the request is obsolete. The request is considered obsolete if there is at least one successfully completed request in the 'right' subarray of the requests.
 */
- (BOOL)_isTaskObsolete:(nonnull DFImageTask *)task {
    // Iterate throught the 'right' subarray of tasks
    for (NSUInteger i = [_imageTasks indexOfObject:task] + 1; i < _imageTasks.count; i++) {
        if ([self _isTaskSuccessfull:_imageTasks[i]]) {
            return YES;
        }
    }
    return NO;
}

- (nonnull NSArray *)imageRequests {
    NSMutableArray *requests = [NSMutableArray new];
    for (DFImageTask *task in _imageTasks) {
        [requests addObject:task.request];
    }
    return [requests copy];
}

@end
