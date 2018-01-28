//
//  LFAudioCapture.m
//  LFLiveKit
//
//  Created by 倾慕 on 16/5/1.
//  Copyright © 2016年 倾慕. All rights reserved.
//

#import "LFAudioCapture.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "InMemoryAudioFile.h"

NSString *const LFAudioComponentFailedToCreateNotification = @"LFAudioComponentFailedToCreateNotification";

@interface LFAudioCapture () {
    
    InMemoryAudioFile *inMemoryAudioFile;
    ExtAudioFileRef             mAudioFileRef;
}

@property (nonatomic, assign) AudioComponentInstance    componetInstance;
@property (nonatomic, assign) AudioComponent            component;
@property (nonatomic, strong) dispatch_queue_t       taskQueue;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) LFLiveAudioConfiguration *configuration;

@end

@implementation LFAudioCapture

#pragma mark -- LiftCycle
- (instancetype)initWithAudioConfiguration:(LFLiveAudioConfiguration *)configuration{
    if(self = [super init]){
        _configuration = configuration;
        self.isRunning = NO;
        self.taskQueue = dispatch_queue_create("com.youku.Laifeng.audioCapture.Queue", NULL);
        
        AVAudioSession *session = [AVAudioSession sharedInstance];
        //将会话设置为活动的或非活动的。注意，激活音频会话是同步(阻塞)操作。因此，我们建议应用程序不能从一个长阻塞操作的线程中激活他们的会话。 请注意，如果会话在运行或运行时设置不活跃，该方法将在iOS 8中连接的应用程序中抛出异常(例如:音频队列、播放器、录音机、转换器、远程I / Os等)。
        [session setActive:YES withOptions:kAudioSessionSetActiveFlag_NotifyOthersOnDeactivation error:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(handleRouteChange:)
                                                     name: AVAudioSessionRouteChangeNotification
                                                   object: session];
        //AVAudioSessionInterruptionNotification:当系统中断音频会话和何时时，注册侦听器将被通知中断已经结束。检查通知的userInfo字典的中断类型——开始或结束。在结束中断通知的情况下，检查userInfo字典以获取AVAudioSessionInterruptionOptions显示音频回放是否应该恢复。
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(handleInterruption:)
                                                     name: AVAudioSessionInterruptionNotification
                                                   object: session];
        
        NSError *error = nil;
        
        [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionMixWithOthers error:nil];
        
        [session setMode:AVAudioSessionModeVideoRecording error:&error];
        
        if (![session setActive:YES error:&error]) {
            [self handleAudioComponentCreationFailure];
        }
        
        //AudioComponentDescription 是用于描述音频组件的唯一标识和标识的结构。
        AudioComponentDescription acd;
        /*componentType类型是相对应的，什么样的功能设置什么样的类型，componentSubType是根据componentType设置的。*/
        acd.componentType = kAudioUnitType_Output; /*一个音频组件的通用的独特的四字节码标识*/
        acd.componentSubType = kAudioUnitSubType_RemoteIO;   /*根据componentType设置相应的类型*/
        acd.componentManufacturer = kAudioUnitManufacturer_Apple; /*厂商的身份验证*/
        acd.componentFlags = 0;  /*如果没有一个明确指定的值，那么它必须被设置为0*/
        acd.componentFlagsMask = 0;   /*如果没有一个明确指定的值，那么它必须被设置为0*/
        
        self.component = AudioComponentFindNext(NULL, &acd);
        
        OSStatus status = noErr;
        status = AudioComponentInstanceNew(self.component, &_componetInstance);
        
        if (noErr != status) {
            [self handleAudioComponentCreationFailure];
        }
        
        UInt32 flagOne = 1;
        /*
         1.一个io unit(其中remote io unit是iphone的三个io unit中的一个)的element 1(也叫bus 1)直接与设备上的输入硬件(比如麦克风)相连;
         
         2.一个io unit的element 0(也叫bus 0)直接与设备上的输出硬件(比如扬声器)相连.
         */
        
        //The Remote I/O unit, by default, has output enabled and input disabled: 默认情况下，远程I / O单元的输出启用和输入禁用
        
        //Enable input scope of input bus for recording:  为记录的输入总线的输出范围应用格式。
        //kAudioOutputUnitProperty_EnableIO:苹果输出属性id  kAudioUnitScope_Input:与设备上的输入硬件(比如麦克风)相连;  kAudioUnitScope_Output:与设备上的输出硬件(扬声器)相连
        AudioUnitSetProperty(self.componetInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &flagOne, sizeof(flagOne));
        
        //调整音频硬件I / O缓冲时间。如果I / O延迟在您的应用程序中至关重要，您可以请求较小的持续时间
        Float32 ioBufferDuration = .005;
        AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(ioBufferDuration),&ioBufferDuration);
        
        UInt32 override=true;
        AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof(override), &override);
                                
        AudioStreamBasicDescription desc = {0};
        /*mSampleRate：是音频格式的采样率，单位为HZ；音频采样率是指录音设备在一秒钟内对声音信号的采样次数，采样频率越高声音的还原就越真实越自然。
        采样频率一般共分为22.05KHz、44.1KHz、48KHz三个等级，22.05KHz只能达到FM广播的声音品质，44.1KHz则是理论上的CD音质界限，48KHz则更加精确一些。对于高于48KHz的采样频率人耳已无法辨别出来了*/
        desc.mSampleRate = _configuration.audioSampleRate;
        //mFormatID：是对应音频格式的ID，即各种格式；每种格式在API有对应说明，如kAudioFormatLinearPCM等
        desc.mFormatID = kAudioFormatLinearPCM;
        /*mFormatFlags：为保存音频数据的方式的说明，如可以根据大端字节序或小端字节序，浮点数或整数以及不同体位去保存数据.
        例如对PCM格式通常我们如下设置：kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked等*/
        desc.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
        //mChannelsPerFrame:每个数据帧中的通道数(声道数目)。声道数是指支持能不同发声的音响的个数，它是衡量音响设备的重要指标之一。
        desc.mChannelsPerFrame = (UInt32)_configuration.numberOfChannels;
        //mFramesPerPacket:每包数据的示例帧数。
        desc.mFramesPerPacket = 1;
        //mBitsPerChannel:在一组数据中每个通道的样本数据的占用位数。 语音每采样点 占用位数
        desc.mBitsPerChannel = 16;
        //mBytesPerFrame:每个单独帧的字节数
        desc.mBytesPerFrame = desc.mBitsPerChannel / 8 * desc.mChannelsPerFrame;
        //mBytesPerPacket:数据包中的字节数。
        desc.mBytesPerPacket = desc.mBytesPerFrame * desc.mFramesPerPacket;
        
        AURenderCallbackStruct cb;
        cb.inputProcRefCon = (__bridge void *)(self);
        cb.inputProc = handleInputBuffer;
        //为记录的输入总线的输出范围应用格式
        status = AudioUnitSetProperty(self.componetInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &desc, sizeof(desc));
        
        status = AudioUnitSetProperty(self.componetInstance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &cb, sizeof(cb));
        
//        AURenderCallbackStruct playStruct;
//        playStruct.inputProc = playCallback;
//        playStruct.inputProcRefCon=(__bridge void * _Nullable)(self);
//        AudioUnitSetProperty(self.componetInstance,
//                             kAudioUnitProperty_SetRenderCallback,
//                             kAudioUnitScope_Input,
//                             0,
//                             &playStruct,
//                             sizeof(playStruct)),
//        
//        //Applying format to input scope of output bus for playing
//        AudioUnitSetProperty(self.componetInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &desc, sizeof(desc));
        
        status = AudioUnitInitialize(self.componetInstance);
        
        if (noErr != status) {
            [self handleAudioComponentCreationFailure];
        }
        
        [session setPreferredSampleRate:_configuration.audioSampleRate error:nil];
        
        
//        //Create an audio file for recording
//        NSString *destinationFilePath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"test.caf"];
//        CFURLRef destinationURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)destinationFilePath, kCFURLPOSIXPathStyle, false);
//        ExtAudioFileCreateWithURL(destinationURL, kAudioFileCAFType, &desc, NULL, kAudioFileFlags_EraseFile, &mAudioFileRef);
//        CFRelease(destinationURL);
//        
//        inMemoryAudioFile=[[InMemoryAudioFile alloc] init];
//        NSString *filepath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"test.caf"];
//        [inMemoryAudioFile open:filepath];
        
        [session setActive:YES error:nil];
    }
    return self;
}

- (void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    dispatch_sync(self.taskQueue, ^{
        if(self.componetInstance){
            AudioOutputUnitStop(self.componetInstance);
            AudioComponentInstanceDispose(self.componetInstance);
            self.componetInstance = nil;
            self.component = nil;
        }
    });
}

#pragma mark -- Setter
- (void)setRunning:(BOOL)running{
    if(_running == running) return;
    _running = running;
    if(_running){
        dispatch_async(self.taskQueue, ^{
            self.isRunning = YES;
            NSLog(@"MicrophoneSource: startRunning");
            AudioOutputUnitStart(self.componetInstance);
        });
    }else{
        self.isRunning = NO;
    }
}

#pragma mark -- CustomMethod
- (void)handleAudioComponentCreationFailure {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LFAudioComponentFailedToCreateNotification object:nil];
    });
}

#pragma mark -- NSNotification
- (void)handleRouteChange:(NSNotification *)notification {
    AVAudioSession *session = [ AVAudioSession sharedInstance ];
    NSString* seccReason = @"";
    NSInteger  reason = [[[notification userInfo] objectForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    //  AVAudioSessionRouteDescription* prevRoute = [[notification userInfo] objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    switch (reason) {
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory:
            seccReason = @"The route changed because no suitable route is now available for the specified category.";
            break;
        case AVAudioSessionRouteChangeReasonWakeFromSleep:
            seccReason = @"The route changed when the device woke up from sleep.";
            break;
        case AVAudioSessionRouteChangeReasonOverride:
            seccReason = @"The output route was overridden by the app.";
            break;
        case AVAudioSessionRouteChangeReasonCategoryChange:
            seccReason = @"The category of the session object changed.";
            break;
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
            seccReason = @"The previous audio output path is no longer available.";
            break;
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
            seccReason = @"A preferred new audio output path is now available.";
            break;
        case AVAudioSessionRouteChangeReasonUnknown:
        default:
            seccReason = @"The reason for the change is unknown.";
            break;
    }
    AVAudioSessionPortDescription *input = [[session.currentRoute.inputs count]?session.currentRoute.inputs:nil objectAtIndex:0];
    if (input.portType == AVAudioSessionPortHeadsetMic) {
        
    }
}

- (void)handleInterruption:(NSNotification *)notification {
    NSInteger reason = 0;
    NSString* reasonStr = @"";
    if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
        //Posted when an audio interruption occurs.
        reason = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] integerValue];
        if (reason == AVAudioSessionInterruptionTypeBegan) {
            if (self.isRunning) {
                dispatch_sync(self.taskQueue, ^{
                    NSLog(@"MicrophoneSource: stopRunning");
                    AudioOutputUnitStop(self.componetInstance);
                });
            }
        }
        
        if (reason == AVAudioSessionInterruptionTypeEnded) {
            reasonStr = @"AVAudioSessionInterruptionTypeEnded";
            NSNumber* seccondReason = [[notification userInfo] objectForKey:AVAudioSessionInterruptionOptionKey] ;
            switch ([seccondReason integerValue]) {
                case AVAudioSessionInterruptionOptionShouldResume:
                    if (self.isRunning) {
                        dispatch_async(self.taskQueue, ^{
                            NSLog(@"MicrophoneSource: stopRunning");
                            AudioOutputUnitStart(self.componetInstance);
                        });
                    }
                    // Indicates that the audio session is active and immediately ready to be used. Your app can resume the audio operation that was interrupted.
                    break;
                default:
                    break;
            }
        }
        
    };
    NSLog(@"handleInterruption: %@ reason %@",[notification name], reasonStr);
}

#pragma mark -- CallBack
static OSStatus handleInputBuffer(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    @autoreleasepool {
        LFAudioCapture *source = (__bridge LFAudioCapture *)inRefCon;
        if(!source) return -1;
        
        AudioBuffer buffer;
        buffer.mData = NULL;
        buffer.mDataByteSize = 0;
        buffer.mNumberChannels = 1;
        
        AudioBufferList buffers;
        buffers.mNumberBuffers = 1;
        buffers.mBuffers[0] = buffer;
        
        OSStatus status = AudioUnitRender(source.componetInstance,
                                          ioActionFlags,
                                          inTimeStamp,
                                          inBusNumber,
                                          inNumberFrames,
                                          &buffers);
        
        if (!source.isRunning) {
            dispatch_sync(source.taskQueue, ^{
                NSLog(@"MicrophoneSource: stopRunning");
                AudioOutputUnitStop(source.componetInstance);
            });
            
            return status;
        }
        
        if (source.muted) {
            for (int i = 0; i < buffers.mNumberBuffers; i++) {
                AudioBuffer ab = buffers.mBuffers[i];
                memset(ab.mData, 0, ab.mDataByteSize);
            }
        }
        
        if(!status) {
            if(source.delegate && [source.delegate respondsToSelector:@selector(captureOutput:audioBuffer:)]){
                [source.delegate captureOutput:source audioBuffer:buffers];
            }
        }
        
        // Now, we have the samples we just read sitting－in buffers in bufferList
//        ExtAudioFileWriteAsync(source->mAudioFileRef, inNumberFrames, &buffers);
        
        return status;
    }
}

OSStatus playCallback(void                                      *inRefCon,
                      AudioUnitRenderActionFlags      *ioActionFlags,
                      const AudioTimeStamp            *inTimeStamp,
                      UInt32                          inBusNumber,
                      UInt32                          inNumberFrames,
                      AudioBufferList                 *ioData){
    printf("play::%d,",inNumberFrames);
    LFAudioCapture *source = (__bridge LFAudioCapture *)inRefCon;
    if(!source) return -1;
    
    /*
     UInt8 *frameBuffer = ioData->mBuffers[0].mData;
     UInt32 count=inNumberFrames*4;
     for (int j = 0; j < count; ){
     UInt32 packet=[this->inMemoryAudioFile getNextFrame];
     frameBuffer[j]=packet;
     frameBuffer[j+1]=packet>>8;
     //Above for the left channel, right channel following
     frameBuffer[j+2]=packet>>16;
     frameBuffer[j+3]=packet>>24;
     j+=4;
     }
     */
    /*
     UInt16 *frameBuffer = ioData->mBuffers[0].mData;
     UInt32 count=inNumberFrames*2;
     for (int j = 0; j < count; ){
     UInt32 packet=[this->inMemoryAudioFile getNextFrame];
     frameBuffer[j]=packet;//left channel
     frameBuffer[j+1]=packet>>16;//right channel
     j+=2;
     }
     */
    
    UInt32 *frameBuffer = ioData->mBuffers[0].mData;
    UInt32 count=inNumberFrames;
    for (int j = 0; j < count; j++){
        frameBuffer[j] = [source->inMemoryAudioFile getNextPacket];//Stereo channels
    }
    
    return noErr;
}
@end
