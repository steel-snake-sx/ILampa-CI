import SwiftUI

// Compatibility name for the former independent WKWebView factory. There must be only
// one runtime: both native background attachment and visible UI use the shared host.
// Navigation, message validation, recovery, and playback belong to LampaHeadlessHost.
typealias LampaWebView = LampaHostContainerView
