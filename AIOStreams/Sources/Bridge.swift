import Foundation
import WebKit

/// The page's `window.aiostreamsApp`: the desktop and Android apps' protocol (version 2),
/// carried by a WebKit message handler one way and `evaluateJavaScript` the other.
@MainActor
final class Bridge: NSObject {
    static let handlerName = "aiostreams"

    weak var webView: WKWebView?
    var onMessage: (String, [String: Any]) -> Void = { _, _ in }
    /// Whether a page has said hello since it last loaded.
    private(set) var connected = false

    func install(into controller: WKUserContentController) {
        controller.add(WeakHandler(self), name: Self.handlerName)
        controller.addUserScript(WKUserScript(
            source: Self.script(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    func pageLoading() {
        connected = false
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the bundled page's own frame speaks to the app.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == WebAssets.scheme,
              let text = message.body as? String,
              let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String
        else { return }
        if type == "hello" {
            connected = true
            return
        }
        onMessage(type, json)
    }

    func send(_ message: [String: Any]) {
        guard let webView, let json = JSON.encode(message) else { return }
        webView.evaluateJavaScript("window.__aiostreamsAppReceive && window.__aiostreamsAppReceive(\(json));")
    }

    private static func literal(_ value: String) -> String {
        JSON.encode(["v": value]).map { String($0.dropFirst(5).dropLast(1)) } ?? "\"\""
    }

    /// Whether the system shows times on a 24-hour clock, which the page's time format follows on Auto.
    private static var uses24HourClock: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    private static func script() -> String {
        """
        (() => {
          if (window.top !== window || window.aiostreamsApp) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
          if (!handler) return;
          const listeners = new Set();
          const send = (message) => handler.postMessage(JSON.stringify(message));
          Object.defineProperty(window, '__aiostreamsAppReceive', {
            value(message) {
              for (const listener of listeners) {
                try {
                  listener(message);
                } catch (error) {
                  console.error(error);
                }
              }
            },
          });
          window.aiostreamsApp = Object.freeze({
            protocol: 2,
            version: \(literal(AppInfo.version)),
            platform: 'ios',
            miniPlayer: false,
            // Picture in Picture, which shows the player's button for it.
            pip: true,
            hours24: \(Self.uses24HourClock ? "true" : "false"),
            device: \(literal(AppInfo.deviceName)),
            deviceId: \(literal(AppInfo.deviceId)),
            send,
            subscribe(listener) {
              listeners.add(listener);
              return () => listeners.delete(listener);
            },
          });
          // Errors go to the app's log, which problem reports read.
          const MAX_REPORTS = 100;
          let reports = 0;
          let lastReport = '';
          const describe = (value) => {
            if (value instanceof Error) return value.stack || value.name + ': ' + value.message;
            if (typeof value === 'string') return value;
            try {
              return JSON.stringify(value);
            } catch {
              return String(value);
            }
          };
          const report = (message) => {
            if (!message || message === lastReport || reports >= MAX_REPORTS) return;
            lastReport = message;
            reports++;
            send({ type: 'web-error', message });
          };
          window.addEventListener('error', (e) =>
            report(e.error ? describe(e.error) : e.message + ' (' + e.filename + ':' + e.lineno + ')')
          );
          window.addEventListener('unhandledrejection', (e) => report('unhandled rejection: ' + describe(e.reason)));
          const consoleError = console.error;
          console.error = (...args) => {
            report(args.map(describe).join(' '));
            consoleError.apply(console, args);
          };
          send({ type: 'hello' });
        })();
        """
    }
}

/// WebKit holds its message handlers strongly; this keeps the bridge free to go.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: Bridge?

    init(_ target: Bridge) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.userContentController(controller, didReceive: message)
        }
    }
}
