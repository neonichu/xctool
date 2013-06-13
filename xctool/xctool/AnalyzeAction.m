//
// Copyright 2013 Facebook
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "AnalyzeAction.h"

#import "Options.h"
#import "XCToolUtil.h"
#import "XcodeSubjectInfo.h"
#import "BuildStateParser.h"
#import "Reporter.h"

@interface BuildTargetsCollector : Reporter

/// Array of @{@"projectName": projectName, @"targetName": targetName}
@property (nonatomic, retain) NSMutableSet *seenTargets;

@end

@implementation BuildTargetsCollector
- (void)beginBuildTarget:(NSDictionary *)event
{
  if (!self.seenTargets) {
    self.seenTargets = [NSMutableSet set];
  }

  [self.seenTargets addObject:@{
   @"projectName": event[kReporter_BeginBuildTarget_ProjectKey],
   @"targetName": event[kReporter_BeginBuildTarget_TargetKey],
   }];
}
@end

@interface AnalyzeAction ()
@property (nonatomic, retain) NSMutableSet *onlySet;
@property (nonatomic, assign) BOOL skipDependencies;
@end

@implementation AnalyzeAction

+ (NSString *)name
{
  return @"analyze";
}

+ (NSArray *)options
{
  return @[[Action actionOptionWithName:@"only"
                                aliases:nil
                            description:
            @"only analyze selected targets, can be used more than once.\n"
            "\tIf this option is specified, its dependencies are assumed to be built."
                              paramName:@"TARGET"
                                  mapTo:@selector(addOnlyOption:)
            ],
           [Action actionOptionWithName:@"skip-deps"
                                aliases:nil
                            description:@"Skip initial build of the scheme"
                                setFlag:@selector(setSkipDependencies:)],
           ];
}

/*! Retrieve the location of the intermediate directory
 */
+ (NSString *)intermediatesDirForProject:(NSString *)projectName
                                  target:(NSString *)targetName
                           configuration:(NSString *)configuration
                                platform:(NSString *)platform
                                 objroot:(NSString *)objroot
{
  return [NSString pathWithComponents:@[
          objroot,
          [projectName stringByAppendingPathExtension:@"build"],
          [NSString stringWithFormat:@"%@%@", configuration, platform],
          [targetName stringByAppendingPathExtension:@"build"],
          ]];
}

+ (void)emitAnalyzerWarningsForProject:(NSString *)projectName
                                target:(NSString *)targetName
                               options:(Options *)options
                      xcodeSubjectInfo:(XcodeSubjectInfo *)xcodeSubjectInfo
                           toReporters:(NSArray *)reporters
{
  static NSRegularExpression *analyzerPlistPathRegex = nil;
  if (!analyzerPlistPathRegex) {
    analyzerPlistPathRegex =
    [NSRegularExpression regularExpressionWithPattern:@"^.*/StaticAnalyzer/.*\\.plist$"
                                              options:0
                                                error:0];
  }

  NSString *path = [[self class]
                    intermediatesDirForProject:projectName
                    target:targetName
                    configuration:[options effectiveConfigurationForSchemeAction:@"AnalyzeAction"
                                                                xcodeSubjectInfo:xcodeSubjectInfo]
                    platform:xcodeSubjectInfo.effectivePlatformName
                    objroot:xcodeSubjectInfo.objRoot];
  NSString *buildStatePath = [path stringByAppendingPathComponent:@"build-state.dat"];

  BuildStateParser *buildState = [[[BuildStateParser alloc] initWithPath:buildStatePath] autorelease];
  for (NSString *path in buildState.nodes) {
    NSTextCheckingResult *result = [analyzerPlistPathRegex
                                    firstMatchInString:path
                                    options:0
                                    range:NSMakeRange(0, path.length)];
    if (result.range.location == NSNotFound) {
      continue;
    }

    NSDictionary *diags = [NSDictionary dictionaryWithContentsOfFile:path];
    for (NSDictionary *diag in diags[@"diagnostics"]) {
      NSString *file = diags[@"files"][[diag[@"location"][@"file"] intValue]];
      file = file.stringByStandardizingPath;
      NSNumber *line = diag[@"location"][@"line"];
      NSNumber *col = diag[@"location"][@"col"];
      NSString *desc = diag[@"description"];

      [reporters makeObjectsPerformSelector:@selector(handleEvent:) withObject:@{
       @"event": kReporter_Events_AnalyzerResult,
        kReporter_AnalyzerResult_ProjectKey: projectName,
         kReporter_AnalyzerResult_TargetKey: targetName,
           kReporter_AnalyzerResult_FileKey: file,
           kReporter_AnalyzerResult_LineKey: line,
         kReporter_AnalyzerResult_ColumnKey: col,
    kReporter_AnalyzerResult_DescriptionKey: desc,
       }];
    }
  }
}

- (id)init
{
  if (self = [super init]) {
    self.onlySet = [NSMutableSet set];
  }
  return self;
}

- (void)addOnlyOption:(NSString *)targetName
{
  [_onlySet addObject:targetName];
}

- (BOOL)performActionWithOptions:(Options *)options
                xcodeSubjectInfo:(XcodeSubjectInfo *)xcodeSubjectInfo
{

  BuildTargetsCollector *buildTargetsCollector = [[[BuildTargetsCollector alloc] init] autorelease];
  NSArray *reporters = [options.reporters arrayByAddingObject:buildTargetsCollector];

  NSArray *buildArgs = [[options xcodeBuildArgumentsForSubject]
                        arrayByAddingObjectsFromArray:
                        [options commonXcodeBuildArgumentsForSchemeAction:@"AnalyzeAction"
                                                         xcodeSubjectInfo:xcodeSubjectInfo]];

  BOOL success = YES;
  if (_onlySet.count) {
    if (!self.skipDependencies) {
      // build everything, and then build with analyze only the specified buildables
      NSArray *args = [buildArgs arrayByAddingObject:@"build"];
      success = RunXcodebuildAndFeedEventsToReporters(args, @"build", [options scheme], reporters);
    }

    if (success) {
      for (NSDictionary *buildable in xcodeSubjectInfo.buildables) {
        if (!buildable[@"buildForAnalyzing"] ||
            ![_onlySet containsObject:buildable[@"target"]]) {
          continue;
        }
        NSArray *args =
        [[options commonXcodeBuildArgumentsForSchemeAction:@"AnalyzeAction"
                                          xcodeSubjectInfo:xcodeSubjectInfo]
         arrayByAddingObjectsFromArray:@[
         @"-project", buildable[@"projectPath"],
         @"-target", buildable[@"target"],
         @"RUN_CLANG_STATIC_ANALYZER=YES",
         [NSString stringWithFormat:@"OBJROOT=%@", xcodeSubjectInfo.objRoot],
         [NSString stringWithFormat:@"SYMROOT=%@", xcodeSubjectInfo.symRoot],
         [NSString stringWithFormat:@"SHARED_PRECOMPS_DIR=%@", xcodeSubjectInfo.sharedPrecompsDir],
         ]];
        success &= RunXcodebuildAndFeedEventsToReporters(args, @"analyze", [options scheme], reporters);
      }
    }
  } else {
    NSArray *args = [buildArgs arrayByAddingObjectsFromArray:@[
                     @"RUN_CLANG_STATIC_ANALYZER=YES",
                     @"build"]];
    success = RunXcodebuildAndFeedEventsToReporters(args, @"analyze", [options scheme], reporters);
    NSLog(@"%@", buildTargetsCollector.seenTargets);
  }

  if (!success) {
    return NO;
  }

  for (NSDictionary *buildable in buildTargetsCollector.seenTargets) {
    if (_onlySet.count && ![_onlySet containsObject:buildable[@"targetName"]]) {
      continue;
    }

    [self.class emitAnalyzerWarningsForProject:buildable[@"projectName"]
                                        target:buildable[@"targetName"]
                                       options:options
                              xcodeSubjectInfo:xcodeSubjectInfo
                                   toReporters:options.reporters];
  }

  return YES;
}

@end
