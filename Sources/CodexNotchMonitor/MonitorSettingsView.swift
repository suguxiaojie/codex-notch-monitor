import SwiftUI

struct MonitorSettingsView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        QuotaStyleSettingsView(store: store)
    }
}
