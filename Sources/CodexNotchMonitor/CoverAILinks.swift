import AppKit
import Foundation

enum CoverAILinks {
    enum Campaign: String {
        case brandAttribution = "brand_attribution"
        case dashboardCard = "dashboard_card"
        case appMenu = "app_menu"
    }

    static func url(for campaign: Campaign) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "coverai.store"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "utm_source", value: "codex_monitor"),
            URLQueryItem(name: "utm_medium", value: "mac_app"),
            URLQueryItem(name: "utm_campaign", value: campaign.rawValue),
        ]

        guard let url = components.url,
              url.scheme == "https",
              url.host == "coverai.store"
        else { return nil }
        return url
    }

    static func open(_ campaign: Campaign) {
        guard let url = url(for: campaign) else { return }
        NSWorkspace.shared.open(url)
    }
}
