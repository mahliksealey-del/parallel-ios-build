import AVFoundation
import Foundation
import MediaToolbox

enum VideoAudioBoostPolicy {
    static let linearGain: Float = 1.9952623 // +6.0 dB
    static let ceiling: Float = 0.98

    static func process(_ samples: inout [Float], gain: Float = linearGain) {
        for index in samples.indices {
            samples[index] = max(-ceiling, min(ceiling, samples[index] * gain))
        }
    }
}

/// Immutable after construction except for callback-owned ramp state. One
/// instance belongs to one MTAudioProcessingTap and is released by finalize.
private final class VideoAudioTapContext {
    let targetGain: Float
    var currentGain: Float = 1
    var format = AudioStreamBasicDescription()
    var rampStep: Float = 0

    init(targetGain: Float) { self.targetGain = targetGain }

    func prepare(maxFrames: CMItemCount, format: UnsafePointer<AudioStreamBasicDescription>) {
        self.format = format.pointee
        rampStep = (targetGain - 1) / Float(max(1, min(maxFrames, 2_400)))
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else { return }

        for frame in 0..<frames {
            if currentGain != targetGain {
                let next = currentGain + rampStep
                currentGain = rampStep >= 0 ? min(targetGain, next) : max(targetGain, next)
            }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channelCount = max(1, Int(buffer.mNumberChannels))
                let values = data.assumingMemoryBound(to: Float.self)
                if buffers.count == 1 {
                    for channel in 0..<channelCount {
                        let index = frame * channelCount + channel
                        values[index] = max(-VideoAudioBoostPolicy.ceiling,
                                            min(VideoAudioBoostPolicy.ceiling,
                                                values[index] * currentGain))
                    }
                } else if frame < Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                    values[frame] = max(-VideoAudioBoostPolicy.ceiling,
                                        min(VideoAudioBoostPolicy.ceiling,
                                            values[frame] * currentGain))
                }
            }
        }
    }
}

enum VideoAudioBoostFactory {
    static func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let retained = Unmanaged.passRetained(
            VideoAudioTapContext(targetGain: VideoAudioBoostPolicy.linearGain)
        )
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<VideoAudioTapContext>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).release()
            },
            prepare: { tap, maxFrames, format in
                Unmanaged<VideoAudioTapContext>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).takeUnretainedValue().prepare(maxFrames: maxFrames, format: format)
            },
            unprepare: nil,
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, frameCount, bufferList, flagsOut, nil, framesOut
                )
                guard status == noErr else { framesOut.pointee = 0; return }
                Unmanaged<VideoAudioTapContext>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).takeUnretainedValue().process(bufferList, frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap
        )
        guard status == noErr, let tap else {
            retained.release()
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
