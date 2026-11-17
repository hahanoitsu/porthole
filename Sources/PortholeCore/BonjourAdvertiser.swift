import dnssd
import Foundation

/// Registers the receiver's Bonjour services so iPhones list it under Screen Mirroring.
///
/// macOS holds a registration until the user allows local network access, so success and failure
/// arrive later, through `onResult`, on the main queue.
final class BonjourAdvertiser {
    /// Service type and, on failure, a description of the error.
    var onResult: ((_ type: String, _ error: String?) -> Void)?

    private var services: [DNSServiceRef] = []

    func register(name: String, type: String, port: UInt16, txt: Data) throws {
        var service: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error: DNSServiceErrorType = txt.withUnsafeBytes { record in
            DNSServiceRegister(&service, 0, 0, name, type, nil, nil, port.bigEndian, UInt16(txt.count), record.baseAddress,
                               { _, _, errorCode, name, type, _, context in
                                   guard let context else { return }
                                   let advertiser = Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue()
                                   advertiser.report(errorCode: errorCode,
                                                     name: name.map { String(cString: $0) } ?? "?",
                                                     type: type.map { String(cString: $0) } ?? "?")
                               }, context)
        }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let service else {
            throw AirPlayError.socket("DNSServiceRegister(\(type)) failed with error \(error)")
        }
        DNSServiceSetDispatchQueue(service, .main)
        services.append(service)
        logInfo("Bonjour: asked to advertise \"\(name)\" as \(type); waiting for confirmation")
    }

    private func report(errorCode: DNSServiceErrorType, name: String, type: String) {
        let serviceType = type.hasPrefix("_airplay") ? "_airplay._tcp" : type.hasPrefix("_raop") ? "_raop._tcp" : type
        if errorCode == DNSServiceErrorType(kDNSServiceErr_NoError) {
            logInfo("Bonjour: advertising \"\(name)\" as \(type)")
            onResult?(serviceType, nil)
        } else if errorCode == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            logError("Bonjour: macOS denied local network access (error \(errorCode))")
            onResult?(serviceType, "macOS denied local network access. Turn on Porthole in System Settings › Privacy & Security › Local Network, then reopen Porthole.")
        } else {
            logError("Bonjour: advertising \(type) failed with error \(errorCode)")
            onResult?(serviceType, "Bonjour error \(errorCode)")
        }
    }

    func stop() {
        services.forEach { DNSServiceRefDeallocate($0) }
        services.removeAll()
    }

    deinit { stop() }
}
