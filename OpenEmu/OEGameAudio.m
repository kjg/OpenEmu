/*
 Copyright (c) 2009, OpenEmu Team
 
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEGameAudio.h"
#import "OEGameCore.h"
#import "TPCircularBuffer.h"
#import "OERingBuffer.h"

typedef struct
{
    TPCircularBuffer *buffer;
    int channelCount;
} OEGameAudioContext;

ExtAudioFileRef recordingFile;

OSStatus RenderCallback(void                       *in,
                        AudioUnitRenderActionFlags *ioActionFlags,
                        const AudioTimeStamp       *inTimeStamp,
                        UInt32                      inBusNumber,
                        UInt32                      inNumberFrames,
                        AudioBufferList            *ioData);

OSStatus RenderCallback(void                       *in,
                        AudioUnitRenderActionFlags *ioActionFlags,
                        const AudioTimeStamp       *inTimeStamp,
                        UInt32                      inBusNumber,
                        UInt32                      inNumberFrames,
                        AudioBufferList            *ioData)
{
    OEGameAudioContext *context = (OEGameAudioContext*)in;
    int availableBytes = 0;
    void *head = TPCircularBufferTail(context->buffer, &availableBytes);
    int bytesRequested = inNumberFrames * sizeof(UInt16) * context->channelCount;
    availableBytes = MIN(availableBytes, bytesRequested);
    int leftover = bytesRequested - availableBytes;
    
    char *outBuffer = ioData->mBuffers[0].mData;
    memcpy(outBuffer, head, availableBytes);
    TPCircularBufferConsume(context->buffer, availableBytes);
    if (leftover)
    {
        NSLog(@"Underrun by %d bytes", leftover);
        outBuffer += availableBytes;
        memset(outBuffer, 0, leftover);
    }
    return 0;
}

void AQRender(void *inUserData,
              AudioQueueRef           inAQ,
              AudioQueueBufferRef     inBuffer);

void AQRender(void *inUserData,
              AudioQueueRef           inAQ,
              AudioQueueBufferRef     inBuffer)
{
    AudioQueueFreeBuffer(inAQ, inBuffer);
}


@interface OEGameAudio ()
{
    OEGameAudioContext context;
}
@end

@implementation OEGameAudio

// No default version for this class
- (id)init
{
    return nil;
}

// Designated Initializer
- (id)initWithCore:(OEGameCore *)core
{
    self = [super init];
    if(self != nil)
    {
        gameCore = core;
        [self createGraph];
    }
    
    return self;
}

- (void)dealloc
{
    AudioQueueDispose(outputQueue, true);
}

- (void)pauseAudio
{
    DLog(@"Stopped audio");
    [self stopAudio];
}

- (void)startAudio
{
    [self createGraph];
}

- (void)stopAudio
{
    AudioQueueStop(outputQueue, true);
}

- (void)createGraph
{
    OSStatus err;
    
    AudioStreamBasicDescription mDataFormat;
    NSUInteger channelCount = [gameCore channelCount];
    mDataFormat.mSampleRate = [gameCore frameSampleRate];
    mDataFormat.mFormatID = kAudioFormatLinearPCM;
    mDataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian;
    mDataFormat.mBytesPerPacket = 2 * channelCount;
    mDataFormat.mFramesPerPacket = 1; // this means each packet in the AQ has two samples, one for each channel -> 4 bytes/frame/packet
    mDataFormat.mBytesPerFrame = 2 * channelCount;
    mDataFormat.mChannelsPerFrame = channelCount;
    mDataFormat.mBitsPerChannel = 16;

    context = (OEGameAudioContext){&[gameCore ringBufferAtIndex:0]->buffer, 2};
    AudioQueueNewOutput(&mDataFormat, AQRender, &context, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &outputQueue);
    

    AudioQueueStart(outputQueue, 0);
    
    //    CFShow(mGraph);
    [self setVolume:[self volume]];
}

- (float)volume
{
    return volume;
}

- (void)setVolume:(float)aVolume
{
    volume = aVolume;
    //    AudioUnitSetParameter(mOutputUnit, kAudioUnitParameterUnit_LinearGain, kAudioUnitScope_Global, 0, volume, 0);
}

- (void)flushBuffer
{
    int availableBytes = 0;
    TPCircularBuffer *ring = &[gameCore ringBufferAtIndex:0]->buffer;
    void *head = TPCircularBufferTail(ring, &availableBytes);
    AudioQueueBufferRef buffer;
    OSStatus err = AudioQueueAllocateBuffer(outputQueue, availableBytes, &buffer); 
    if (err == noErr) {        
        memcpy(buffer->mAudioData, head, availableBytes);
        buffer->mAudioDataByteSize = availableBytes;
        
        TPCircularBufferConsume(ring, availableBytes);
        err = AudioQueueEnqueueBuffer (outputQueue, buffer, 0, nil);
        if (err != noErr) NSLog(@"AudioQueueEnqueueBuffer() error: %d", err);
    } else {
        NSLog(@"AudioQueueAllocateBuffer() error: %d", err); 
        return;
    }
}

@end
