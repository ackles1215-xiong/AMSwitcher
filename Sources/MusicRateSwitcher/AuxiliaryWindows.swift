import AppKit
import RateSwitcherCore
import SwiftUI

/// Hosts the About/Welcome and Diagnostics windows. Each is created lazily and
/// reused so repeated clicks just bring the existing window forward.
final class AuxiliaryWindows {
    private var aboutWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?

    func showAbout(firstLaunch: Bool) {
        let view = AboutView(firstLaunch: firstLaunch) { [weak self] in self?.aboutWindow?.close() }
        aboutWindow = present(aboutWindow, title: "开源许可", view: view)
    }

    func showDiagnostics(text: String) {
        let view = DiagnosticsView(text: text)
        diagnosticsWindow = present(diagnosticsWindow, title: "诊断摘要", view: view, resizable: true)
    }

    private func present<Content: View>(_ existing: NSWindow?, title: String, view: Content, resizable: Bool = false) -> NSWindow {
        let window = existing ?? makeWindow(resizable: resizable)
        window.title = title
        let host = NSHostingController(rootView: view)
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        if existing == nil { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindow(resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        return window
    }
}

// MARK: - About

struct AboutView: View {
    let firstLaunch: Bool
    let dismiss: () -> Void

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AMSwitcher").font(.system(size: 20, weight: .semibold))
            Text("版本 \(version) · Apple Music 采样率匹配")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            Text("基于 MusicRateSwitcher 修改。原项目版权 © 2026 Arczotis。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                Text(Self.license).font(.system(size: 10)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 210)
            HStack { Spacer(); Button("关闭", action: dismiss).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 400)
    }

    private static let license = """
    MIT License

    Copyright (c) 2026 MusicRateSwitcher contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    let text: String
    @StateObject private var copied = Flag()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.brandGradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("诊断摘要").font(.system(size: 15, weight: .semibold))
                    Text("反馈问题时附上这段信息会很有帮助").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 240)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("打开日志文件") { NSWorkspace.shared.open(Diagnostics.shared.logURL) }
                Spacer()
                Button(copied.value ? "已复制" : "复制摘要") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied.value = true
                }
                .buttonStyle(BrandButtonStyle(prominent: true, fullWidth: false))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 380)
    }
}

struct BrandButtonStyle: ButtonStyle {
    var prominent: Bool
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.08), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
