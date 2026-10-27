import Foundation

enum Edition {
    #if CLIENT_EDITION
    static let isClient = true
    static let daemonLabel = "local.vpn.singbox"
    static let agentLabel = "local.vpn.monitor"
    #else
    static let isClient = false
    static let daemonLabel = "dev.vpnstatusbar.singbox"
    static let agentLabel = "dev.vpnstatusbar.monitor"
    #endif
}
