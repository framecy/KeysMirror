import AppKit
import SwiftUI

struct AppPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [RunningApplication] = []
    @State private var searchText = ""

    let onSelect: (RunningApplication) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("选择正在运行的应用")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }

            TextField("按应用名或 bundle identifier 搜索", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filteredApplications) { application in
                Button {
                    onSelect(application)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        if let icon = application.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "app")
                                .frame(width: 28, height: 28)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.displayName)
                                .foregroundStyle(.primary)
                            Text(application.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .task {
            applications = AppResolver.shared.runningApplications()
        }
    }

    private var filteredApplications: [RunningApplication] {
        if searchText.isEmpty {
            return applications
        }

        return applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }
}
