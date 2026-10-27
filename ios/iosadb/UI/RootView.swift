import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TellyscopeRootView()
        .animation(.easeInOut(duration: 0.2), value: model.connectionState.isConnected)
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                TVADBStatusBanner(message: UserFacingFailure.sanitized(error), isError: true) {
                    model.errorMessage = nil
                }
                .padding(.horizontal, 16)
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let notice = model.noticeMessage {
                TVADBStatusBanner(message: notice, isError: false) {
                    model.noticeMessage = nil
                }
                .padding(.horizontal, 16)
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: model.errorMessage)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: model.noticeMessage)
        .sensoryFeedback(.error, trigger: model.errorMessage)
        .sensoryFeedback(.success, trigger: model.noticeMessage)
        .task(id: model.noticeMessage) {
            guard let notice = model.noticeMessage else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled, model.noticeMessage == notice else { return }
            withAnimation {
                model.noticeMessage = nil
            }
        }
        .task(id: model.errorMessage) {
            guard let error = model.errorMessage else { return }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled, model.errorMessage == error else { return }
            withAnimation {
                model.errorMessage = nil
            }
        }
    }
}
