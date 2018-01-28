//
//  InMemoryAudioFile.h
//  高仿映客
//
//  Created by none on 17/6/19.
//  Copyright © 2017年 JIAAIR. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioFile.h>
#include <sys/time.h>

@interface InMemoryAudioFile : NSObject {
    AudioStreamBasicDescription     mDataFormat;
    AudioFileID                     mAudioFile;
    UInt32                          bufferByteSize;
    SInt64                          mCurrentPacket;
    UInt32                          mNumPacketsToRead;
    AudioStreamPacketDescription    *mPacketDescs;
    SInt64                          packetCount;
    UInt32                          *audioData;
    SInt64                          packetIndex;
    
}
//opens a wav file
-(OSStatus)open:(NSString *)filePath;
//gets the infor about a wav file, stores it locally
-(OSStatus)getFileInfo;

//gets the next packet from the buffer, returns -1 if we have reached the end of the buffer
-(UInt32)getNextPacket;

//gets the current index (where we are up to in the buffer)
-(SInt64)getIndex;

//reset the index to the start of the file
-(void)reset;

@end
