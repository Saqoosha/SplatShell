import AppKit
import WebKit

// A native window around a bundled SuperSplat build.
//
//   SplatShell [--web-root <dir>] [--pixels <W>x<H>] [--stochastic <mode>]
//              [--bench <splat file>] [--snapshot <png>] [--eval <js>] [<splat file> ...]
//
// --web-root overrides the SuperSplat build inside the app bundle.
// --stochastic sets SuperSplat's stochastic rendering mode: movement (default),
// auto, disabled or enabled.
// --bench opens the file, runs a fixed set of render measurements, prints one
// JSON line prefixed with "RESULT " and exits.
// --snapshot <png> writes the window contents to the file once the first
// opened file has settled into a sorted frame, then exits. After any
// stochastic frame the snapshot shows the dithered picture even though the
// window shows the sorted one, so pair it with --stochastic disabled.
// --eval <js> runs the text as the body of an async function in the page once
// the first opened file has settled, and prints what it returns (before the
// snapshot, when both are given).

struct Options {
    var webRoot: URL?
    var bench: URL?
    var snapshot: URL?
    var eval: String?
    var stochastic = "movement"
    var pixels: (width: Int, height: Int)?
    var files: [URL] = []

    init(arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--web-root":
                if let v = it.next() { webRoot = URL(fileURLWithPath: v) }
            case "--bench":
                if let v = it.next() { bench = URL(fileURLWithPath: v) }
            case "--snapshot":
                if let v = it.next() { snapshot = URL(fileURLWithPath: v) }
            case "--eval":
                eval = it.next()
            case "--stochastic":
                if let v = it.next(), ["disabled", "enabled", "movement", "auto"].contains(v) { stochastic = v }
            case "--pixels":
                if let v = it.next() {
                    let parts = v.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { pixels = (parts[0], parts[1]) }
                }
            default:
                // AppKit passes its own "-NSSomething value" defaults through argv
                if arg.hasPrefix("-") { _ = it.next() } else { files.append(URL(fileURLWithPath: arg)) }
            }
        }
    }
}

func emit(_ line: String) {
    print(line)
    fflush(stdout)
}

// Runs in the page before SuperSplat's own scripts.
let shellScript = #"""
(() => {
  const post = (kind, text) => { try { window.webkit.messageHandlers.shell.postMessage({ kind, text: String(text) }); } catch (e) {} };
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const shell = window.__shell = { post, wait, errors: [] };

  window.addEventListener('error', e => { shell.errors.push('error: ' + e.message); post('error', e.message); });
  window.addEventListener('unhandledrejection', e => { const m = (e.reason && e.reason.message) || e.reason; shell.errors.push('rejection: ' + m); post('rejection', m); });
  const origError = console.error.bind(console);
  console.error = (...a) => { post('console.error', a.map(String).join(' ')); origError(...a); };

  shell.ready = (async () => {
    while (!(window.scene && window.editor)) await wait(50);
    await wait(300);
    // Scenes of tens of millions of splats cannot be sorted every frame at
    // display rate, so the default here is 'movement': the unsorted stochastic
    // mode while the camera moves, one sorted frame when it stops. SuperSplat's
    // own default, 'auto', only does that once a sorted frame takes over 60 ms.
    window.scene.events.fire('view.setStochastic', window.__shellConfig.stochastic);
    post('ready', '');
  })();

  // Ask the app for files. The click opens WebKit's file chooser, which the
  // app answers with the paths it wants opened, so the page gets real File
  // objects that are read from disk on demand.
  shell.pick = () => new Promise(resolve => {
    const input = document.createElement('input');
    input.type = 'file'; input.multiple = true; input.style.display = 'none';
    document.body.appendChild(input);
    input.addEventListener('change', () => { const files = [...input.files]; input.remove(); resolve(files); });
    input.addEventListener('cancel', () => { input.remove(); resolve([]); });
    input.click();
  });

  // Resolves once the scene has shown a sorted (not stochastic) frame and
  // stayed that way for half a second, or after `timeout` ms.
  shell.settled = async (timeout) => {
    const s = window.scene, start = performance.now();
    let calmSince = null;
    while (performance.now() - start < timeout) {
      const calm = !s.movingRender && !s.pendingResolve;
      if (!calm) calmSince = null;
      else if (calmSince === null) calmSince = performance.now();
      else if (performance.now() - calmSince >= 500) break;
      await wait(50);
    }
    return { waitedMs: Math.round(performance.now() - start), movingRender: s.movingRender, pendingResolve: s.pendingResolve,
      mode: s.events.invoke('view.stochastic'), lastFrameStochastic: s.frameTimings.stochastic };
  };

  shell.importFiles = files => window.scene.events.invoke('import', files.map(f => ({ filename: f.name, contents: f })));

  shell.open = async () => {
    await shell.ready;
    const files = await shell.pick();
    if (!files.length) return;
    const names = files.map(f => f.name).join(', ');
    post('opening', names);
    try {
      await shell.importFiles(files);
      window.scene.events.fire('camera.focus');
      post('opened', names);
      post('settled', JSON.stringify(await shell.settled(20000)));
    } catch (err) {
      post('open-failed', (err && err.message) || err);
    }
  };
})();
"""#

// Added in --bench mode. Mirrors the measurement used in Chrome so the
// engines can be compared.
let benchScript = #"""
(() => {
  const shell = window.__shell, wait = shell.wait;
  const b = window.__bench = { state: 'idle' };

  b.measure = (ms, orbit) => new Promise(resolve => {
    const s = window.scene, cam = s.camera, ft = s.frameTimings;
    ft.gpu.length = 0; ft.cpu.length = 0;
    const gaps = [], gpu = [], cpu = []; let stoch = 0, n = 0;
    let last = performance.now(); const start = last; const az0 = cam.azim, el0 = cam.elevation;
    const tick = () => {
      const now = performance.now(); gaps.push(now - last); last = now; n++;
      if (ft.gpu.length) gpu.push(ft.gpu[ft.gpu.length - 1]);
      if (ft.cpu.length) cpu.push(ft.cpu[ft.cpu.length - 1]);
      if (ft.stochastic) stoch++;
      if (orbit) cam.setAzimElev(az0 + (now - start) * 0.03, el0, 0); else s.forceRender = true;
      if (now - start < ms) requestAnimationFrame(tick);
      else {
        const q = (a, p) => { if (!a.length) return null; const c = [...a].sort((x, y) => x - y); return +c[Math.min(c.length - 1, Math.floor(c.length * p))].toFixed(2); };
        gaps.shift();
        resolve({ frames: n, fps: +(1000 * gaps.length / gaps.reduce((x, y) => x + y, 0)).toFixed(1),
          gapMs: { p50: q(gaps, .5), p95: q(gaps, .95), max: q(gaps, 1) },
          gpuMs: { p50: q(gpu, .5), p95: q(gpu, .95) }, cpuMs: { p50: q(cpu, .5), p95: q(cpu, .95) },
          stochasticFrames: stoch, target: [ft.width, ft.height] });
      }
    };
    requestAnimationFrame(tick);
  });

  const pass = async (mode, interacting) => {
    const s = window.scene;
    s.events.fire('view.setStochastic', mode); s.forceInteracting = interacting; await wait(500);
    const r = await b.measure(5000, true);
    s.forceInteracting = false;
    return r;
  };

  b.runAll = async () => {
    const r = b.result = { env: { ua: navigator.userAgent, origin: location.origin, secure: isSecureContext, dpr: devicePixelRatio, viewport: [innerWidth, innerHeight], hasGPU: 'gpu' in navigator } };
    try {
      b.state = 'waiting-for-app';
      await shell.ready;
      const s = window.scene, e = s.events, cam = s.camera;
      r.env.gpuTiming = s.frameTimings.gpuSupported;
      r.env.device = s.app.graphicsDevice.deviceType;
      r.env.defaultMode = e.invoke('view.stochastic');

      b.state = 'picking';
      const files = await shell.pick();
      if (!files.length) throw new Error('the app supplied no file');
      r.name = files[0].name; r.sizeGB = +(files[0].size / 1073741824).toFixed(2);

      b.state = 'loading'; b.t0 = performance.now();
      await shell.importFiles(files);
      r.loadS = +((performance.now() - b.t0) / 1000).toFixed(1);
      r.splats = (s.elements || []).filter(x => x.numSplats !== undefined).map(x => x.numSplats);

      b.state = 'measuring';
      // Sorted passes run in 'auto' with the engage threshold out of reach:
      // 'disabled' also switches off the GPU timer, 'auto' keeps it sampling.
      const initialMode = e.invoke('view.stochastic');
      const initialEngageMs = s.autoEngageMs;
      s.autoEngageMs = 1e9;
      e.fire('camera.focus'); await wait(3000);
      e.fire('view.setStochastic', 'auto'); await wait(500);
      r.farStill = await b.measure(4000, false);
      r.farOrbitSorted = await pass('auto', false);
      r.farOrbitMovement = await pass('movement', true);
      e.fire('view.setStochastic', 'auto');
      cam.setDistance(cam.distance * 0.15, 0); await wait(2500);
      r.nearStill = await b.measure(4000, false);
      r.nearOrbitSorted = await pass('auto', false);
      r.nearOrbitMovement = await pass('movement', true);
      s.autoEngageMs = initialEngageMs;
      e.fire('view.setStochastic', initialMode);
      b.state = 'done';
    } catch (err) {
      r.error = String((err && err.message) || err);
      b.state = 'failed';
    }
    r.errors = shell.errors.slice(-10);
  };

  b.status = () => JSON.stringify({ state: b.state, elapsedS: b.t0 ? +((performance.now() - b.t0) / 1000).toFixed(1) : null });
})();
"""#

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let options: Options
    var window: NSWindow!
    var webView: WKWebView!
    var schemeHandler: WebAppSchemeHandler?

    /// The page posts "ready" once SuperSplat has started; opens wait for it.
    var pageReady = false
    var queuedFiles: [URL] = []
    /// Files the next file chooser the page opens is answered with.
    var filesForNextChooser: [URL]?

    var pollTimer: Timer?
    var lastState = ""

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = NSSize(width: 1440, height: 900)
        if let p = options.pixels {
            size = NSSize(width: CGFloat(p.width) / scale, height: CGFloat(p.height) / scale)
        }

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "shell")
        config.userContentController.addUserScript(
            WKUserScript(
                source: "window.__shellConfig = { stochastic: '\(options.stochastic)' };",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: shellScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if options.bench != nil {
            config.userContentController.addUserScript(
                WKUserScript(source: benchScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        let webRoot = options.webRoot ?? Bundle.main.resourceURL?.appendingPathComponent("web")
        if let webRoot, FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("index.html").path) {
            let handler = WebAppSchemeHandler(root: webRoot)
            schemeHandler = handler
            config.setURLSchemeHandler(handler, forURLScheme: WebAppSchemeHandler.scheme)
        }

        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "SplatShell"
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("main")
        if options.pixels != nil { window.setContentSize(size) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        emit("LAUNCH scale=\(scale) points=\(Int(size.width))x\(Int(size.height)) webRoot=\(webRoot?.path ?? "none")")

        guard schemeHandler != nil else {
            webView.loadHTMLString(
                "<body style='font:14px -apple-system;padding:40px'>No SuperSplat build found. Pass --web-root &lt;dir&gt; or bundle one at Resources/web.</body>",
                baseURL: nil)
            if options.bench != nil { fail("no web root") }
            return
        }
        open(options.files)
        webView.load(URLRequest(url: WebAppSchemeHandler.indexURL))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    // MARK: Opening files

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.open(panel.urls) }
        }
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard pageReady else {
            queuedFiles += urls
            return
        }
        filesForNextChooser = urls
        webView.evaluateJavaScript("window.__shell.open(); true") { _, error in
            if let error { emit("ERROR open: \(error.localizedDescription)") }
        }
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        if let urls = filesForNextChooser {
            filesForNextChooser = nil
            completionHandler(urls)
            return
        }
        // SuperSplat's own Open / Import commands
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: Page messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let text = body["text"] as? String ?? ""
        emit("PAGE \(kind): \(text)")
        switch kind {
        case "ready":
            pageReady = true
            if options.bench != nil {
                startBench()
            } else {
                let files = queuedFiles
                queuedFiles = []
                open(files)
            }
        case "opened":
            window.title = text
        case "settled":
            let snapshot = { [weak self] in
                guard let self, let target = self.options.snapshot else { return }
                // one more beat so the last frame has been presented
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.writeSnapshot(to: target) }
            }
            guard let script = options.eval else { return snapshot() }
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): emit("EVAL \(value)")
                case .failure(let error): emit("EVAL failed: \(error.localizedDescription)")
                }
                snapshot()
            }
        case "open-failed":
            let alert = NSAlert()
            alert.messageText = "Could not open the file"
            alert.informativeText = text
            alert.beginSheetModal(for: window)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("page did not load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("web content process terminated")
    }

    func writeSnapshot(to target: URL) {
        webView.takeSnapshot(with: nil) { image, error in
            if let tiff = image?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
               (try? png.write(to: target)) != nil {
                emit("SNAPSHOT \(target.path)")
            } else {
                emit("FAILED snapshot: \(error?.localizedDescription ?? "could not encode or write")")
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: Benchmark

    func startBench() {
        guard let file = options.bench else { return }
        filesForNextChooser = [file]
        webView.evaluateJavaScript("window.__bench.runAll(); true") { _, error in
            if let error { emit("ERROR bench: \(error.localizedDescription)") }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        webView.evaluateJavaScript("window.__bench.status()") { [weak self] value, _ in
            guard let self, let text = value as? String,
                  let data = text.data(using: .utf8),
                  let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = status["state"] as? String else { return }
            if state != self.lastState {
                self.lastState = state
                emit("STATE \(text)")
            }
            if state == "done" || state == "failed" { self.finish() }
        }
    }

    func finish() {
        pollTimer?.invalidate()
        webView.evaluateJavaScript("JSON.stringify(window.__bench.result)") { value, _ in
            emit("MEMORY \(webKitProcessMemory())")
            emit("RESULT \(value as? String ?? "null")")
            NSApp.terminate(nil)
        }
    }

    func fail(_ reason: String) {
        pollTimer?.invalidate()
        emit("MEMORY \(webKitProcessMemory())")
        emit("FAILED \(reason)")
        if options.bench != nil { exit(2) }
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SplatShell", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SplatShell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit SplatShell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // No Undo / Redo / Select All items: their key equivalents would be
        // taken by the menu before the page sees them, and SuperSplat binds
        // those keys to its own edit history and selection.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

/// Resident memory of every WebKit helper process over 200 MB, largest first.
/// These helpers are not children of this process, so other apps' web views
/// appear here too.
func webKitProcessMemory() -> String {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,rss=,etime=,comm="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return "ps failed" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int, String)? in
        let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard cols.count == 4, cols[3].contains("com.apple.WebKit"), let kb = Int(cols[1]), kb > 200_000 else { return nil }
        let kind = cols[3].split(separator: ".").last.map(String.init) ?? "?"
        return (kb / 1024, "\(kind) pid=\(cols[0]) \(kb / 1024)MB up=\(cols[2])")
    }
    return rows.sorted { $0.0 > $1.0 }.map(\.1).joined(separator: "; ")
}

let app = NSApplication.shared
let delegate = AppDelegate(options: Options(arguments: CommandLine.arguments))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
