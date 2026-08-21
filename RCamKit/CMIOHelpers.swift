import Foundation
import CoreMediaIO

// MARK: - CoreMediaIO object helpers

enum CMIOHelpers {
    static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for scalar in string.unicodeScalars {
            result = result << 8 | UInt32(scalar.value)
        }
        return result
    }

    static func allDeviceUIDs() -> [String] {
        var addr = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &addr, 0, nil,
                                        dataSize, &dataUsed, &deviceIDs) == noErr else { return [] }
        return deviceIDs.compactMap {
            stringProperty($0, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
        }
    }

    static func findDevice(uid: String) -> CMIOObjectID? {
        var addr = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &addr, 0, nil,
                                        dataSize, &dataUsed, &deviceIDs) == noErr else { return nil }
        return deviceIDs.first {
            stringProperty($0, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == uid
        }
    }

    static func findStream(device: CMIOObjectID, named name: String) -> CMIOStreamID? {
        var addr = address(CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIDs = [CMIOStreamID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil,
                                        dataSize, &dataUsed, &streamIDs) == noErr else { return nil }
        return streamIDs.first {
            stringProperty($0, CMIOObjectPropertySelector(kCMIOObjectPropertyName)) == name
        }
    }

    static func stringProperty(_ object: CMIOObjectID,
                               _ selector: CMIOObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard CMIOObjectHasProperty(object, &addr) else { return nil }
        var value: CFString?
        var dataUsed: UInt32 = 0
        let size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &dataUsed, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Read a custom string-valued device property by four-char code.
    static func readCustomString(device: CMIOObjectID, code: String) -> String? {
        stringProperty(device, CMIOObjectPropertySelector(fourCC(code)))
    }

    /// Write a custom string-valued device property by four-char code.
    @discardableResult
    static func writeCustomString(device: CMIOObjectID, code: String, value: String) -> Bool {
        var addr = address(CMIOObjectPropertySelector(fourCC(code)))
        guard CMIOObjectHasProperty(device, &addr) else { return false }
        var cfValue = value as CFString?
        let size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfValue) {
            CMIOObjectSetPropertyData(device, &addr, 0, nil, size, $0)
        }
        return status == noErr
    }
}
