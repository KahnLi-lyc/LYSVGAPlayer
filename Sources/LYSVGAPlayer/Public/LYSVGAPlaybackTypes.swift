public enum LYSVGARepeatMode: Equatable, Sendable {
    case once
    case count(UInt)
    case forever
}

public enum LYSVGAEndBehavior: Equatable, Sendable {
    case clear
    case holdStartFrame
    case holdEndFrame
}

public enum LYSVGAPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case finished
    case failed
}
