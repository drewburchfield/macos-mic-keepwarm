import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import MicWarmCore

// MARK: - CoreAudio Helpers

public func getAudioProperty<T>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    var value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value)
    guard status == noErr else { return nil }
    return value.pointee
}

public func allowSystemIdleSleep() {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertySleepingIsAllowed,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var allowSleep: UInt32 = 1

    let status = AudioObjectSetPropertyData(
        systemObject,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &allowSleep)

    guard status == noErr else {
        log("[power] Could not allow system idle sleep (OSStatus: \(status))")
        return
    }

    let configuredValue: UInt32? = getAudioProperty(
        systemObject,
        selector: kAudioHardwarePropertySleepingIsAllowed)
    guard configuredValue == 1 else {
        log("[power] Could not verify that system idle sleep is allowed")
        return
    }

    log("[power] System idle sleep allowed during microphone capture")
}

public func getStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &name)
    guard status == noErr else { return nil }
    return name as String
}

public func getAllAudioDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
    return devices
}

public func transportTypeName(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in"
    case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeFireWire: return "firewire"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeUnknown: return "unknown"
    default:
        let chars = [
            Character(UnicodeScalar((type >> 24) & 0xFF)!),
            Character(UnicodeScalar((type >> 16) & 0xFF)!),
            Character(UnicodeScalar((type >> 8) & 0xFF)!),
            Character(UnicodeScalar(type & 0xFF)!)
        ]
        return "0x\(String(format: "%08X", type)) (\(String(chars)))"
    }
}

public func describeDevice(_ deviceID: AudioDeviceID) -> String {
    let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "?"
    let uid = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "?"
    let transport: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyTransportType) ?? 0
    let isAlive: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) ?? 0
    let isRunning: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunning) ?? 0
    let isRunningSomewhere: UInt32 = getAudioProperty(deviceID, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
    let hogPID: pid_t = getAudioProperty(deviceID, selector: kAudioDevicePropertyHogMode) ?? -1

    var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var inputSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
    let inputStreams = Int(inputSize) / MemoryLayout<AudioStreamID>.size

    return "\(name) [id=\(deviceID) uid=\(uid) transport=\(transportTypeName(transport)) alive=\(isAlive) running=\(isRunning) runningSomewhere=\(isRunningSomewhere) hogPID=\(hogPID) inputStreams=\(inputStreams)]"
}

// The first input stream's active (virtual) format. The clearest in-process signal for the
// Bluetooth profile in use: HFP/SCO presents as low-rate mono (8k/16k/24kHz by codec; healthy
// AirPods wideband voice is 24000 Hz).
// Comparing this at flat-onset vs recovery tells us whether the SCO link was actually carrying audio.
public func inputStreamFormatDescription(_ deviceID: AudioDeviceID) -> String {
    guard deviceID > 0 else { return "no device" }
    var streamsAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioStreamID>.size
    guard count > 0 else { return "no input streams" }
    var streams = [AudioStreamID](repeating: 0, count: count)
    AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &size, &streams)

    var fmtAddr = AudioObjectPropertyAddress(
        mSelector: kAudioStreamPropertyVirtualFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(streams[0], &fmtAddr, 0, nil, &asbdSize, &asbd)
    guard status == noErr else { return "format query failed (status \(status), streams=\(count))" }

    let fid = asbd.mFormatID
    let fourcc = "\(Character(UnicodeScalar((fid >> 24) & 0xFF) ?? " "))"
        + "\(Character(UnicodeScalar((fid >> 16) & 0xFF) ?? " "))"
        + "\(Character(UnicodeScalar((fid >> 8) & 0xFF) ?? " "))"
        + "\(Character(UnicodeScalar(fid & 0xFF) ?? " "))"
    return "sampleRate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) format='\(fourcc)' streams=\(count)"
}

public func logAllDevices(prefix: String) {
    let devices = getAllAudioDeviceIDs()
    log("\(prefix) --- All audio devices (\(devices.count)) ---")
    for d in devices {
        log("\(prefix)   \(describeDevice(d))")
    }

    let defaultInput: AudioDeviceID? = getAudioProperty(
        AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultInputDevice)
    if let di = defaultInput {
        log("\(prefix)   Default input: \(getStringProperty(di, selector: kAudioObjectPropertyName) ?? "?") [id=\(di)]")
    } else {
        log("\(prefix)   Default input: NONE")
    }
}

