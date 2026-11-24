import SwiftUI
import UIKit

enum CameraMode {
    case photo, video
}

struct CameraScreen: View {
    @ObservedObject var model: CameraModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let background = Color(red: 0.035, green: 0.042, blue: 0.072)
    private let panel = Color(red: 0.071, green: 0.081, blue: 0.119)
    private let ink = Color(red: 0.965, green: 0.965, blue: 0.925)
    private let accent = Color(red: 0.865, green: 0.960, blue: 0.470)
    private let recordRed = Color(red: 1.0, green: 0.355, blue: 0.335)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.vertical, 8)

            GeometryReader { area in
                let width = max(0, min(area.size.width, area.size.height * 9 / 16))
                viewfinder
                    .frame(width: width, height: width * 16 / 9)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 8)

            controls
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .foregroundStyle(ink)
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: model.notice) { _, value in announce(value) }
        .onChange(of: model.problem) { _, value in announce(value) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(ink, lineWidth: 2)
                    .frame(width: 23, height: 19)
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .overlay { RoundedRectangle(cornerRadius: 3).stroke(background, lineWidth: 2) }
                    .frame(width: 13, height: 11)
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
            Text("雙鏡")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if model.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(recordRed).frame(width: 8, height: 8)
                    Text(recordTime).monospacedDigit()
                }
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("正在錄影")
                .accessibilityValue(recordTime)
            } else {
                HStack(spacing: 6) {
                    if model.busy && !model.ready {
                        ProgressView().controlSize(.mini).tint(ink)
                    } else {
                        Circle().fill(model.ready ? accent : .gray).frame(width: 7, height: 7)
                    }
                    Text(model.busy ? "處理中" : model.ready ? "雙鏡頭就緒" : model.problem == nil ? "準備中" : "相機未就緒")
                        .font(.caption.weight(.medium))
                }
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(panel))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var viewfinder: some View {
        ZStack {
            panel
            CameraPreview(surface: model.preview)
                .accessibilityHidden(true)
            if let problem = model.problem {
                Color.black.opacity(0.72)
                ViewThatFits(in: .vertical) {
                    problemPanel(problem)
                    ScrollView { problemPanel(problem) }
                }
            } else if !model.ready && !model.isRecording {
                VStack(spacing: 12) {
                    ProgressView().tint(accent)
                    Text("正在開啟前後鏡頭…")
                        .font(.subheadline)
                        .foregroundStyle(ink.opacity(0.8))
                }
            }
            if let notice = model.notice, !notice.isEmpty, model.problem == nil {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(.black.opacity(0.8)))
                        .padding(12)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func problemPanel(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.needsSettings {
                Button("開啟設定") {
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        openURL(settings)
                    }
                }
                .buttonStyle(CameraActionStyle(face: accent, label: background))
            }
            Button("重試") { model.retry() }
                .buttonStyle(CameraActionStyle(face: model.needsSettings ? panel : accent,
                                               label: model.needsSettings ? ink : background))
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var controls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                modeButton(.photo, label: "拍照")
                modeButton(.video, label: "錄影")
            }
            .padding(3)
            .background(Capsule().fill(panel))
            .disabled(!model.ready || model.busy || model.isRecording || model.problem != nil)
            .accessibilityElement(children: .contain)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.frontIsPrimary ? "前鏡頭為主" : "後鏡頭為主")
                        .font(.caption.weight(.medium))
                    if model.mode == .video && (model.ready || model.isRecording) {
                        Label(model.micEnabled ? "收音開啟" : "靜音錄影",
                              systemImage: model.micEnabled ? "mic.fill" : "mic.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(model.micEnabled ? ink.opacity(0.7) : accent)
                    }
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { model.shutter() } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(ink, lineWidth: 3)
                            .frame(width: 70, height: 70)
                        if model.isRecording {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(recordRed)
                                .frame(width: 27, height: 27)
                        } else {
                            Circle()
                                .fill(model.mode == .photo ? ink : recordRed)
                                .frame(width: 57, height: 57)
                        }
                    }
                    .padding(4)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canPressShutter)
                .opacity(canPressShutter ? 1 : 0.4)
                .accessibilityLabel(model.isRecording ? "停止錄影" : model.mode == .photo ? "拍攝雙鏡頭照片" : "開始雙鏡頭錄影")

                let canSwap = model.ready && !model.busy && !model.isRecording && model.problem == nil
                Button { model.swap() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(panel))
                }
                .buttonStyle(.plain)
                .disabled(!canSwap)
                .opacity(canSwap ? 1 : 0.4)
                .accessibilityLabel("交換主副鏡頭")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func modeButton(_ mode: CameraMode, label: String) -> some View {
        let active = model.mode == mode
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                model.mode = mode
            }
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? background : ink.opacity(0.72))
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(Capsule().fill(active ? accent : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var canPressShutter: Bool {
        model.isRecording || (model.ready && !model.busy && model.problem == nil)
    }

    private var recordTime: String {
        let seconds = max(0, Int(model.elapsed))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func announce(_ value: String?) {
        if let value, !value.isEmpty, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: value)
        }
    }
}

private struct CameraActionStyle: ButtonStyle {
    let face: Color
    let label: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(label)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(Capsule().fill(face))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
