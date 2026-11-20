import AVFoundation
import Foundation
import MediaToolbox

/// Original, bounded first-party dynamics for supported decoded float PCM.
/// This is a sample-peak guard, NOT a calibrated true-peak/final-device limiter.
/// Independent AVPlayers/third-party apps are not in a common master bus.
enum VideoAudioBoostPolicy {
    static let linearGain: Float = 1.9952623 // max requested +6dB makeup
    static let ceiling: Float = 0.90 // deliberate intersample headroom

    static func process(_ samples: inout [Float], gain: Float = linearGain) {
        var dynamics = VideoAudioDynamics(sampleRate: 48_000)
        for index in samples.indices {
            let input = samples[index]
            samples[index] = input.isFinite
                ? input * dynamics.outputGain(forInputPeak: abs(input), makeup: gain)
                : 0
        }
    }
}

/// Stateful linked-channel envelope detector. One instance per audio tap.
/// All processing uses stack scalars; no allocation, lock or main-actor hop
/// inside the real-time callback. Peak guard acts immediately; its transient
/// distortion/true-peak behavior still requires physical and offline tests.
struct VideoAudioDynamics {
    private var detector: Float = 0
    private var compressionGain: Float = 1
    private let detectorAttack: Float
    private let detectorRelease: Float
    private let reductionAttack: Float
    private let reductionRelease: Float

    init(sampleRate: Double) {
        let rate = Float(sampleRate.isFinite && sampleRate > 1000 ? sampleRate : 48_000)
        detectorAttack = exp(-1 / (0.005 * rate))
        detectorRelease = exp(-1 / (0.150 * rate))
        reductionAttack = exp(-1 / (0.003 * rate))
        reductionRelease = exp(-1 / (0.150 * rate))
    }

    mutating func outputGain(forInputPeak peak: Float, makeup: Float) -> Float {
        guard peak.isFinite, peak >= 0, makeup.isFinite, makeup >= 0 else { return 0 }
        let coefficient = peak > detector ? detectorAttack : detectorRelease
        detector = coefficient * detector + (1 - coefficient) * peak

        let levelDB = 20 * log10(max(detector, 0.000001))
        // -18dBFS threshold, 6dB soft knee, 2.5:1 ratio. Starting
        // engineering values, NOT calibrated speech or hearing presets.
        let above = levelDB + 18
        let knee: Float = 6
        let ratioReduction: Float = 0.6 // 1 - 1/2.5
        let reductionDB: Float
        if above <= -knee / 2 {
            reductionDB = 0
        } else if above >= knee / 2 {
            reductionDB = ratioReduction * above
        } else {
            let position = above + knee / 2
            reductionDB = ratioReduction * position * position / (2 * knee)
        }
        let targetReduction = pow(10 as Float, -reductionDB / 20)
        let gainCoefficient = targetReduction < compressionGain
            ? reductionAttack : reductionRelease
        compressionGain = gainCoefficient * compressionGain +
            (1 - gainCoefficient) * targetReduction

        // Instantaneous safety guard. Unlike hard sample clamping this
        // adjusts both stereo channels by the same frame gain. No claim
        // of lookahead or intersample/true-peak compliance.
        let requested = makeup * compressionGain
        // Reserve a small floating-point multiplication margin: a cap of
        // exactly 0.9 / 0.8 rounds back to 0.90000004 in Float32.
        // Guarding at 0.8999 ensures the *actual output* remains <= 0.9,
        // rather than merely weakening a peak-boundary assertion.
        let safeCeiling = VideoAudioBoostPolicy.ceiling - 0.0001
        return peak > 0 ? min(requested, safeCeiling / peak) : requested
    }
}

/// Immutable across callbacks except callback-owned gain/envelope state.
private final class VideoAudioTapContext {
    let targetGain: Float
    var currentGain: Float = 1
    var format = AudioStreamBasicDescription()
    var rampStep: Float = 0
    var dynamics = VideoAudioDynamics(sampleRate: 48_000)

    init(targetGain: Float) { self.targetGain = targetGain }

    func prepare(maxFrames: CMItemCount, format: UnsafePointer<AudioStreamBasicDescription>) {
        self.format = format.pointee
        dynamics = VideoAudioDynamics(sampleRate: self.format.mSampleRate)
        // Avoid a sudden +6 dB jump on engagement.
        rampStep = (targetGain - 1) / Float(max(1, min(maxFrames, 2_400)))
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard frames > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0 else { return }

        let channels = Int(format.mChannelsPerFrame)
        let planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard (1...8).contains(channels) else { return }
        if planar {
            guard buffers.count == channels else { return }
        } else {
            guard buffers.count == 1 else { return }
        }
        for buffer in buffers {
            let expectedChannels = planar ? 1 : channels
            guard buffer.mData != nil,
                  Int(buffer.mNumberChannels) == expectedChannels,
                  Int(buffer.mDataByteSize) >= frames * expectedChannels * MemoryLayout<Float>.size
            else { return } // do not partially process malformed buffers
        }

        for frame in 0..<frames {
            if currentGain != targetGain {
                let next = currentGain + rampStep
                currentGain = rampStep >= 0 ? min(targetGain, next) : max(targetGain, next)
            }
            // Linked stereo/multichannel detection preserves relative spatial balance.
            var inputPeak: Float = 0
            for buffer in buffers {
                let values = buffer.mData!.assumingMemoryBound(to: Float.self)
                let frameChannels = planar ? 1 : channels
                for channel in 0..<frameChannels {
                    let value = values[frame * frameChannels + channel]
                    if value.isFinite { inputPeak = max(inputPeak, abs(value)) }
                }
            }
            let frameGain = dynamics.outputGain(forInputPeak: inputPeak, makeup: currentGain)
            for buffer in buffers {
                let values = buffer.mData!.assumingMemoryBound(to: Float.self)
                let frameChannels = planar ? 1 : channels
                for channel in 0..<frameChannels {
                    let index = frame * frameChannels + channel
                    let value = values[index]
                    values[index] = value.isFinite ? value * frameGain : 0
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
        var unmanagedTap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects,
            &unmanagedTap
        )
        guard status == noErr, let tap = unmanagedTap?.takeRetainedValue() else {
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
