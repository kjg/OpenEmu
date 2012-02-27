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

static void StretchSamples(int16_t *outBuf, const int16_t *inBuf,
                           int outFrames, int inFrames, int channels)
{
    int frame;
    float ratio = outFrames / (float)inFrames;
    
    for (frame = 0; frame < outFrames; frame++) {
        float iFrame = frame / ratio, iFrameF = floorf(iFrame);
        float lerp = iFrame - iFrameF;
        int iFrameI = iFrameF;
        int ch;
        
        for (ch = 0; ch < channels; ch++) {
            int a, b, c;
            
            a = inBuf[(iFrameI+0)*channels+ch];
            b = inBuf[(iFrameI+1)*channels+ch];
            
            c = a + lerp*(b-a);
            c = MAX(c, SHRT_MIN);
            c = MIN(c, SHRT_MAX);
            
            outBuf[frame*channels+ch] = c;
        }
    }
}

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
    int bytesRequested = inNumberFrames * sizeof(SInt16) * context->channelCount;
    availableBytes = MIN(availableBytes, bytesRequested);
    int leftover = bytesRequested - availableBytes;
    char *outBuffer = ioData->mBuffers[0].mData;

    if (leftover > 0) {
        // time stretch
        // FIXME this works a lot better with a larger buffer
        int framesRequested = inNumberFrames;
        int framesAvailable = availableBytes / (sizeof(SInt16) * context->channelCount);
        StretchSamples((int16_t*)outBuffer, head, framesRequested, framesAvailable, context->channelCount);
    } else {
        memcpy(outBuffer, head, availableBytes);
    }
    
    
    TPCircularBufferConsume(context->buffer, availableBytes);
    return noErr;
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
