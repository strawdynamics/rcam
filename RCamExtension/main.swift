import Foundation
import CoreMediaIO

let providerSource = RCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
