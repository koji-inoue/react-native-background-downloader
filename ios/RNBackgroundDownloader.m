//
//  RNFileBackgroundDownload.m
//  EkoApp
//
//  Created by Elad Gil on 20/11/2017.
//  Copyright © 2017 Eko. All rights reserved.
//
//
#import "RNBackgroundDownloader.h"
#import "RNBGDTaskConfig.h"

#define URL_TO_CONFIG_MAP_KEY @"com.eko.bgdownloadmap"

static CompletionHandler storedCompletionHandler;

@implementation RNBackgroundDownloader {
    NSURLSession *urlSession;
    NSURLSessionConfiguration *sessionConfig;
    NSMutableDictionary<NSString *, RNBGDTaskConfig *> *urlToConfigMap;
    NSMutableDictionary<NSNumber *, RNBGDTaskConfig *> *taskToConfigMap;
    NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *idToTaskMap;
    NSMutableDictionary<NSString *, NSData *> *idToResumeDataMap;
    NSMutableDictionary<NSString *, NSNumber *> *idToPercentMap;
    NSMutableDictionary<NSString *, NSDictionary *> *progressReports;
    NSOperationQueue *downloadOperationsQueue;
    NSDate *lastProgressReport;
}

NSInteger const THROTTLE = 0.017;

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue
{
    return dispatch_queue_create("com.eko.backgrounddownloader", DISPATCH_QUEUE_SERIAL);
}

+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"downloadComplete", @"downloadProgress", @"downloadFailed", @"downloadBegin"];
}

- (NSDictionary *)constantsToExport {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    
    return @{
             @"documents": [paths firstObject],
             @"TaskRunning": @(NSURLSessionTaskStateRunning),
             @"TaskSuspended": @(NSURLSessionTaskStateSuspended),
             @"TaskCanceling": @(NSURLSessionTaskStateCanceling),
             @"TaskCompleted": @(NSURLSessionTaskStateCompleted)
             };
}

- (id) init {
    self = [super init];
    if (self) {
        urlToConfigMap = [self deserialize:[[NSUserDefaults standardUserDefaults] objectForKey:URL_TO_CONFIG_MAP_KEY]];
        if (urlToConfigMap == nil) {
            urlToConfigMap = [[NSMutableDictionary alloc] init];
        }
        taskToConfigMap = [[NSMutableDictionary alloc] init];
        idToTaskMap = [[NSMutableDictionary alloc] init];
        idToResumeDataMap= [[NSMutableDictionary alloc] init];
        idToPercentMap = [[NSMutableDictionary alloc] init];
        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
        sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:sessonIdentifier];
        sessionConfig.HTTPMaximumConnectionsPerHost = 1;
        downloadOperationsQueue = [[NSOperationQueue alloc] init];
        progressReports = [[NSMutableDictionary alloc] init];
        lastProgressReport = [[NSDate alloc] init];
    }
    return self;
}

- (void)lazyInitSession {
    if (urlSession == nil) {
        urlSession = [NSURLSession sessionWithConfiguration:sessionConfig delegate:self delegateQueue:downloadOperationsQueue];
    }
}

- (void)removeTaskFromMap: (NSURLSessionTask *)task {
    NSNumber *taskId = @(task.taskIdentifier);
	if (taskId == nil) {
		return;
	}
    RNBGDTaskConfig *taskConfig = taskToConfigMap[taskId];
    [taskToConfigMap removeObjectForKey:taskId];
    [urlToConfigMap removeObjectForKey:task.currentRequest.URL.absoluteString];
    [[NSUserDefaults standardUserDefaults] setObject:[self serialize: urlToConfigMap] forKey:URL_TO_CONFIG_MAP_KEY];
    if (taskConfig) {
        [idToTaskMap removeObjectForKey:taskConfig.id];
        [idToPercentMap removeObjectForKey:taskConfig.id];
    }
    if (taskToConfigMap.count == 0) {
        [urlSession invalidateAndCancel];
        urlSession = nil;
    }
}

+ (void)setCompletionHandlerWithIdentifier: (NSString *)identifier completionHandler: (CompletionHandler)completionHandler {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
    if ([sessonIdentifier isEqualToString:identifier]) {
        storedCompletionHandler = completionHandler;
    }
}


#pragma mark - JS exported methods
RCT_EXPORT_METHOD(download: (NSDictionary *) options) {
    NSString *identifier = options[@"id"];
    NSString *url = options[@"url"];
    NSString *destination = options[@"destination"];
    NSDictionary *headers = options[@"headers"];
    if (identifier == nil || url == nil || destination == nil) {
        NSLog(@"[RNBackgroundDownloader] - [Error] id, url and destination must be set");
        return;
    }
    [self lazyInitSession];
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:url]];
    if (headers != nil) {
        for (NSString *headerKey in headers) {
            [request setValue:[headers valueForKey:headerKey] forHTTPHeaderField:headerKey];
        }
    }
    
    NSURLSessionDownloadTask *task = [urlSession downloadTaskWithRequest:request];
    RNBGDTaskConfig *taskConfig = [[RNBGDTaskConfig alloc] initWithDictionary: @{@"id": identifier, @"destination": destination}];
    taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
    idToTaskMap[identifier] = task;
    idToPercentMap[identifier] = @0.0;
    [task resume];
}

RCT_EXPORT_METHOD(pauseTask: (NSString *)identifier) {
    NSURLSessionDownloadTask *task = idToTaskMap[identifier];
    if (task != nil && task.state == NSURLSessionTaskStateRunning) {
        [task suspend];
    }
}

RCT_EXPORT_METHOD(resumeTask: (NSString *)identifier) {
    NSURLSessionDownloadTask *task = idToTaskMap[identifier];
    if (task != nil && task.state == NSURLSessionTaskStateSuspended) {
		RNBGDTaskConfig *taskCofig = taskToConfigMap[@(task.taskIdentifier)];
		if (taskCofig != nil) {
			taskCofig.reportedBegin = NO;
		}
        [task resume];
    }
}

RCT_EXPORT_METHOD(stopTask: (NSString *)identifier) {
    NSURLSessionDownloadTask *task = idToTaskMap[identifier];
    if (task != nil) {
        [task cancel];
        [self removeTaskFromMap:task];
    }
}

RCT_EXPORT_METHOD(checkForExistingDownloads: (RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    [self lazyInitSession];
    [urlSession getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
        NSMutableArray *idsFound = [[NSMutableArray alloc] init];
        for (NSURLSessionDownloadTask *foundTask in downloadTasks) {
            NSURLSessionDownloadTask __strong *task = foundTask;
            RNBGDTaskConfig *taskConfig = urlToConfigMap[task.currentRequest.URL.absoluteString];
            if (taskConfig) {
                if (task.state == NSURLSessionTaskStateCompleted && task.countOfBytesReceived < task.countOfBytesExpectedToReceive) {
                    if (task.error && task.error.code == -999 && task.error.userInfo[NSURLSessionDownloadTaskResumeData] != nil) {
                        task = [urlSession downloadTaskWithResumeData:task.error.userInfo[NSURLSessionDownloadTaskResumeData]];
                    } else {
                        task = [urlSession downloadTaskWithURL:foundTask.currentRequest.URL];
                    }
                    [task resume];
                }
                NSNumber *percent = foundTask.countOfBytesExpectedToReceive > 0 ? [NSNumber numberWithFloat:(float)task.countOfBytesReceived/(float)foundTask.countOfBytesExpectedToReceive] : @0.0;
                [idsFound addObject:@{
                                      @"id": taskConfig.id,
                                      @"state": [NSNumber numberWithInt: task.state],
                                      @"bytesWritten": [NSNumber numberWithLongLong:task.countOfBytesReceived],
                                      @"totalBytes": [NSNumber numberWithLongLong:foundTask.countOfBytesExpectedToReceive],
                                      @"percent": percent
                                      }];
                taskConfig.reportedBegin = NO;
                taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
                idToTaskMap[taskConfig.id] = task;
                idToPercentMap[taskConfig.id] = percent;
            } else {
                [task cancel];
            }
        }
        resolve(idsFound);
    }];
}

#pragma mark - NSURLSessionDownloadDelegate methods
- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location {
    RNBGDTaskConfig *taskCofig = taskToConfigMap[@(downloadTask.taskIdentifier)];
    if (taskCofig != nil) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *destURL = [NSURL fileURLWithPath:taskCofig.destination];
        [fileManager createDirectoryAtURL:[destURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [fileManager removeItemAtURL:destURL error:nil];
        NSError *moveError;
        BOOL moved = [fileManager moveItemAtURL:location toURL:destURL error:&moveError];
        if (self.bridge) {
            if (moved) {
                [self sendEventWithName:@"downloadComplete" body:@{@"id": taskCofig.id}];
            } else {
                [self sendEventWithName:@"downloadFailed" body:@{@"id": taskCofig.id, @"error": [moveError localizedDescription]}];
            }
        }
        [self removeTaskFromMap:downloadTask];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    RNBGDTaskConfig *taskCofig = taskToConfigMap[@(downloadTask.taskIdentifier)];
    if (taskCofig != nil) {
        if (!taskCofig.reportedBegin) {
            [self sendEventWithName:@"downloadBegin" body:@{@"id": taskCofig.id, @"expectedBytes": [NSNumber numberWithLongLong: totalBytesExpectedToWrite]}];
            urlToConfigMap[downloadTask.currentRequest.URL.absoluteString] = taskCofig;
            [[NSUserDefaults standardUserDefaults] setObject:[self serialize: urlToConfigMap] forKey:URL_TO_CONFIG_MAP_KEY];
            taskCofig.reportedBegin = YES;
        }
        
        NSNumber *prevPercent = idToPercentMap[taskCofig.id];
        NSNumber *percent = [NSNumber numberWithFloat:(float)totalBytesWritten/(float)totalBytesExpectedToWrite];
        if ([percent floatValue] - [prevPercent floatValue] > 0.01f) {
            progressReports[taskCofig.id] = @{@"id": taskCofig.id, @"written": [NSNumber numberWithLongLong: totalBytesWritten], @"total": [NSNumber numberWithLongLong: totalBytesExpectedToWrite], @"percent": percent};
            idToPercentMap[taskCofig.id] = percent;
        }
        
        NSDate *now = [[NSDate alloc] init];
        if ([now timeIntervalSinceDate:lastProgressReport] > THROTTLE && progressReports.count > 0) {
            if (self.bridge) {
                [self sendEventWithName:@"downloadProgress" body:[progressReports allValues]];
            }
            lastProgressReport = now;
            [progressReports removeAllObjects];
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    RNBGDTaskConfig *taskCofig = taskToConfigMap[@(task.taskIdentifier)];
    if (error != nil && error.code != -999 && taskCofig != nil) {
        if (self.bridge) {
            [self sendEventWithName:@"downloadFailed" body:@{@"id": taskCofig.id, @"error": [error localizedDescription]}];
        }
        [self removeTaskFromMap:task];
    }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (storedCompletionHandler) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            storedCompletionHandler();
            storedCompletionHandler = nil;
        }];
    }
}

#pragma mark - serialization
- (NSData *)serialize: (id)obj {
    return [NSKeyedArchiver archivedDataWithRootObject:obj];
}

- (id)deserialize: (NSData *)data {
    if (data == nil) {
        return nil;
    }
    
    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

@end
