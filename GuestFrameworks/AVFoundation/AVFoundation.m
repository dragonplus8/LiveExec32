#import <AVFoundation/AVFoundation.h>

/*
 * The generated AVFoundation shim only emits Objective-C classes.  Legacy
 * binaries also bind these framework-owned NSString constants eagerly, so
 * provide their iOS 6-compatible values in the guest image.
 */
NSString *const AVLayerVideoGravityResizeAspect =
    @"AVLayerVideoGravityResizeAspect";
NSString *const AVMediaCharacteristicLegible =
    @"AVMediaCharacteristicLegible";
NSString *const AVPlayerItemDidPlayToEndTimeNotification =
    @"AVPlayerItemDidPlayToEndTimeNotification";
NSString *const AVAudioSessionInterruptionNotification =
    @"AVAudioSessionInterruptionNotification";
NSString *const AVAudioSessionInterruptionOptionKey =
    @"AVAudioSessionInterruptionOptionKey";
NSString *const AVAudioSessionInterruptionTypeKey =
    @"AVAudioSessionInterruptionTypeKey";
NSString *const AVEncoderAudioQualityKey =
    @"AVEncoderQualityKey";
NSString *const AVFormatIDKey =
    @"AVFormatIDKey";
NSString *const AVLinearPCMBitDepthKey =
    @"AVLinearPCMBitDepthKey";
NSString *const AVLinearPCMIsBigEndianKey =
    @"AVLinearPCMIsBigEndianKey";
NSString *const AVLinearPCMIsFloatKey =
    @"AVLinearPCMIsFloatKey";
NSString *const AVNumberOfChannelsKey =
    @"AVNumberOfChannelsKey";
NSString *const AVSampleRateKey =
    @"AVSampleRateKey";

/*
 * AVCaptureSessionPreset values. Same situation as the constants above --
 * AVCaptureSession itself is a generated shim, but these free-floating
 * preset strings aren't part of any class's method encoding, so they need
 * to be provided here by hand too. Real AVFoundation's values are just the
 * symbol name as a string.
 */
NSString *const AVCaptureSessionPresetPhoto = @"AVCaptureSessionPresetPhoto";
NSString *const AVCaptureSessionPresetHigh = @"AVCaptureSessionPresetHigh";
NSString *const AVCaptureSessionPresetMedium =
    @"AVCaptureSessionPresetMedium";
NSString *const AVCaptureSessionPresetLow = @"AVCaptureSessionPresetLow";
NSString *const AVCaptureSessionPreset352x288 =
    @"AVCaptureSessionPreset352x288";
NSString *const AVCaptureSessionPreset640x480 =
    @"AVCaptureSessionPreset640x480";
NSString *const AVCaptureSessionPreset960x540 =
    @"AVCaptureSessionPreset960x540";
NSString *const AVCaptureSessionPreset1280x720 =
    @"AVCaptureSessionPreset1280x720";
NSString *const AVCaptureSessionPreset1920x1080 =
    @"AVCaptureSessionPreset1920x1080";
NSString *const AVCaptureSessionPresetiFrame960x540 =
    @"AVCaptureSessionPresetiFrame960x540";
NSString *const AVCaptureSessionPresetiFrame1280x720 =
    @"AVCaptureSessionPresetiFrame1280x720";
NSString *const AVCaptureSessionPresetInputPriority =
    @"AVCaptureSessionPresetInputPriority";

/*
 * A capture session almost always asks for AVMediaTypeVideo (and often
 * Audio) in the same breath as a preset, so add these proactively rather
 * than waiting for the next crash to name them one at a time.
 */
NSString *const AVMediaTypeVideo = @"vide";
NSString *const AVMediaTypeAudio = @"soun";
NSString *const AVMediaTypeMuxed = @"muxx";
