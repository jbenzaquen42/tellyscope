import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("lastHost") private var host = "192.168.1.100"
    @AppStorage("lastPort") private var port = "5555"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.top, 34)

                    VStack(spacing: 6) {
                        Text("TVADB")
                            .font(.largeTitle.bold())
                        Text("text.manage_android_devices_on_your_network_from_iphone")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 14) {
                        LabeledContent("text.android_ip") {
                            TextField("192.168.1.100", text: $host)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Divider()
                        LabeledContent("text.adb_port") {
                            TextField("5555", text: $port)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    Button {
                        if model.connectionState.isConnecting {
                            model.cancelConnection()
                        } else {
                            Task { await model.connect(host: host, portText: port) }
                        }
                    } label: {
                        HStack {
                            if model.isBusy { ProgressView().tint(.white) }
                            Text(buttonTitle).fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        (model.isBusy && !model.connectionState.isConnecting)
                            || host.isEmpty
                            || port.isEmpty
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Label("text.before_connecting", systemImage: "info.circle")
                            .font(.headline)
                        Text("text.1_connect_the_iphone_and_android_device_to_the_same_tr_8e24eca3")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("text.for_android_11_return_to_the_device_page_select_the_di_6f53b081")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private var buttonTitle: String {
        if model.connectionState.isConnecting {
            return L10n.string("text.cancel_connection")
        }
        return L10n.string("text.connect_device")
    }
}
