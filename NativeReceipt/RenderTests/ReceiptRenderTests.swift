import XCTest
import SwiftUI
import WebKit
import AVFAudio
import ReceiptCore
@testable import SuishouLedger

/// Native SwiftUI rendering evidence. This does not claim to test the system's
/// actual Shortcuts host, animations or re-signing on a physical iPhone.
@MainActor
final class ReceiptRenderTests: XCTestCase {
    func testQuietPaperSoundsAreBundledAndDecodable() throws {
        XCTAssertNotNil(ReceiptSound.soundID(for: .printing))
        XCTAssertNotNil(ReceiptSound.soundID(for: .tearing))
        for (name, duration) in [("paper_feed", ReceiptMotionTiming.feedDuration), ("paper_tear", ReceiptMotionTiming.tearDuration)] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "wav"))
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, duration, accuracy: 0.005)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            if name == "paper_feed" {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                let values = try XCTUnwrap(buffer.floatChannelData?[0])
                let rate = file.processingFormat.sampleRate
                let window = Int(rate * 0.04)
                var energy: [Double] = []
                for start in stride(from: Int(rate * 0.16), to: Int(buffer.frameLength) - Int(rate * 0.2) - window, by: window) {
                    var total = 0.0
                    for i in start..<(start + window) { total += Double(values[i]) * Double(values[i]) }
                    energy.append(sqrt(total / Double(window)))
                }
                let sorted = energy.sorted()
                XCTAssertGreaterThan(try XCTUnwrap(sorted.first), 0.015, "Feed audio must remain audible between frames")
                XCTAssertGreaterThan(try XCTUnwrap(sorted.first) / sorted[sorted.count / 2], 0.65, "No periodic sound gates")
            }
        }
    }
    func testLedgerFillsWindowAndKeepsSafeAreas() async throws {
        let controllerClass = try XCTUnwrap(NSClassFromString("LedgerController") as? UIViewController.Type)
        let controller = controllerClass.init()
        let nav = UINavigationController(rootViewController: controller)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: UIScreen.main.bounds) }
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        let web = try XCTUnwrap(controller.value(forKey: "web") as? WKWebView)
        // Fixture only: never load the production ledger or personal records.
        web.loadHTMLString("""
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>html,body{margin:0;background:#fdfbfe;color:#24232b;font:17px -apple-system}
        header{padding:calc(max(env(safe-area-inset-top),var(--app-safe-area-top,0px)) + 16px) 22px 16px;font-weight:700}
        main{margin:16px 22px;padding:24px;background:#f1ecfb;border-radius:22px}
        footer{position:fixed;bottom:0;left:0;right:0;background:white;padding:18px 24px calc(max(env(safe-area-inset-bottom),var(--app-safe-area-bottom,0px)) + 12px);text-align:center}
        #safe{position:absolute;padding-top:max(env(safe-area-inset-top),var(--app-safe-area-top,0px));padding-bottom:max(env(safe-area-inset-bottom),var(--app-safe-area-bottom,0px))}</style>
        <header>随手账</header><main>全屏布局预览<br><br>背景延伸至屏幕边缘</main><footer>流水　　　　　统计</footer><div id="safe"></div>
        """, baseURL: URL(string: "https://ledger.xiaokai123.de5.net/ledger"))
        var ready = false
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('safe') && parseFloat(getComputedStyle(document.getElementById('safe')).paddingTop) > 0")) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready, "Local HTML fixture must finish loading")
        window.layoutIfNeeded()
        XCTAssertTrue(nav.isNavigationBarHidden, "Do not duplicate the ledger header")
        XCTAssertEqual(web.convert(web.bounds, to: window), window.bounds, "Web background must cover the entire window")
        XCTAssertEqual(web.scrollView.contentInset, .zero, "Native wrapper must not add a second content inset")
        let insets = try await web.evaluateJavaScript("({top:parseFloat(getComputedStyle(document.getElementById('safe')).paddingTop), bottom:parseFloat(getComputedStyle(document.getElementById('safe')).paddingBottom)})") as? [String: Double]
        XCTAssertGreaterThan(try XCTUnwrap(insets?["top"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(insets?["bottom"]), 0)
        // WKWebView content is composited out-of-process; drawHierarchy can
        // return only the background despite a fully loaded page.
        let image = try await web.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: image)
        attachment.name = "fullscreen-ledger-fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLedgerKeepsOneScaleAcrossLoadsAndViewportUpdatesWhileScrolling() async throws {
        let controllerClass = try XCTUnwrap(NSClassFromString("LedgerController") as? UIViewController.Type)
        let controller = controllerClass.init()
        let nav = UINavigationController(rootViewController: controller)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: UIScreen.main.bounds) }
        window.rootViewController = nav; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        let web = try XCTUnwrap(controller.value(forKey: "web") as? WKWebView)
        // Local synthetic documents only: navigate away and return to verify
        // that neither disabled zoom nor enabled zoom leaks to the wrong page.
        for (index, address) in [
            "https://ledger.xiaokai123.de5.net/ledger",
            "https://example.test/help",
            "https://suishou-ledger-0726.qq2301796536.chatgpt.site/ledger/",
            "https://ledger.xiaokai123.de5.net/ledger"
        ].enumerated() {
            let ledger = index != 1
            let viewport = index == 3 ? "" : "<meta name=viewport content='width=device-width, initial-scale=1, minimum-scale=0.5, maximum-scale=5, user-scalable=yes, viewport-fit=cover'>"
            web.loadHTMLString("""
            <!doctype html><html><head>\(viewport)<style>
            body{margin:0;padding:60px 20px;box-sizing:border-box;min-height:2400px;font:16px -apple-system}
            input{font-size:12px;width:180px}</style></head>
            <body data-fixture='\(index)'><label>金额<input id=amount value=23.00></label><p>滚动验证</p></body></html>
            """, baseURL: URL(string: address))
            var ready = false
            for _ in 0..<100 {
                let loaded = (try? await web.evaluateJavaScript("document.readyState==='complete' && document.body.dataset.fixture==='\(index)'")) as? Bool == true
                let scaleSettled = ledger ? abs(web.scrollView.maximumZoomScale - 1) < 0.01 : web.scrollView.maximumZoomScale > 1.1
                if loaded && scaleSettled { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(ready, "Zoom policy must settle after navigation \(index)")
            if !ledger { continue }
            XCTAssertEqual(web.scrollView.minimumZoomScale, 1, accuracy: 0.01)
            XCTAssertEqual(web.scrollView.maximumZoomScale, 1, accuracy: 0.01)
            // WebKit owns/reconfigures its gesture recognizers. Verify the
            // effective zoom constraint instead of a transient enabled flag.
            print("Ledger zoom fixture \(index): pinchEnabled=\(String(describing: web.scrollView.pinchGestureRecognizer?.isEnabled)), min=\(web.scrollView.minimumZoomScale), max=\(web.scrollView.maximumZoomScale)")
            for attemptedScale in [2.0, 0.5] {
                web.scrollView.setZoomScale(attemptedScale, animated: false)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(web.scrollView.zoomScale, 1, accuracy: 0.01, "Zoom must remain fixed after an attempted scale change")
            }
            XCTAssertTrue(web.scrollView.isScrollEnabled)
            XCTAssertTrue(web.scrollView.panGestureRecognizer.isEnabled)
            XCTAssertNotNil(web.scrollView.refreshControl)
            // A later page render must not undo the App's viewport constraint.
            _ = try await web.evaluateJavaScript("document.querySelector('meta[name=viewport]').content='width=device-width, initial-scale=1, maximum-scale=5'; document.getElementById('amount').focus();")
            try await Task.sleep(for: .milliseconds(250))
            let scale = try await web.evaluateJavaScript("window.visualViewport.scale") as? Double
            XCTAssertEqual(try XCTUnwrap(scale), 1, accuracy: 0.01)
            XCTAssertEqual(web.scrollView.maximumZoomScale, 1, accuracy: 0.01)
            let width = try await web.evaluateJavaScript("window.innerWidth") as? Double
            XCTAssertEqual(try XCTUnwrap(width), Double(web.bounds.width), accuracy: 1)
            _ = try await web.evaluateJavaScript("document.getElementById('amount').blur()")
            // Keyboard dismissal restores WebKit's scroll offset asynchronously.
            // Wait for the visual viewport to settle before requesting the
            // independent scroll, instead of racing blur with scrollTo.
            var stableViewportSamples = 0
            var previousViewportHeight: Double?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                let state = try await web.evaluateJavaScript("({editing:document.activeElement.id==='amount',height:window.visualViewport.height})") as? [String: Any]
                let height = try XCTUnwrap(state?["height"] as? Double)
                let settled = state?["editing"] as? Bool == false && height > 0 && previousViewportHeight.map { abs(height - $0) < 0.5 } == true
                stableViewportSamples = settled ? stableViewportSamples + 1 : 0
                previousViewportHeight = height
                if stableViewportSamples >= 3 { break }
            }
            XCTAssertGreaterThanOrEqual(stableViewportSamples, 3, "Viewport must settle after ending input before checking scrolling")
            _ = try await web.evaluateJavaScript("window.scrollTo(0,240)")
            var offset = 0.0
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                let measuredOffset = try await web.evaluateJavaScript("window.scrollY") as? Double
                offset = try XCTUnwrap(measuredOffset)
                if offset > 100 { break }
            }
            XCTAssertGreaterThan(offset, 100, "Fixing scale must preserve vertical scrolling after navigation \(index)")
        }
    }

    func testAppHostedPaperDoesNotRequestASystemSnippet() async {
        actor Host {
            var calls = 0
            func reload() { calls += 1 }
        }
        let host = Host()
        let inApp = ReceiptMotionDriver.refresh(inApp: true) { await host.reload() }
        await inApp()
        let backgroundCalls = await host.calls
        XCTAssertEqual(backgroundCalls, 0)
        let shortcut = ReceiptMotionDriver.refresh(inApp: false) { await host.reload() }
        await shortcut()
        let visibleCalls = await host.calls
        XCTAssertEqual(visibleCalls, 1)
    }

    func testV7ShowsPaidAmountOnPaperBeforeNetworkAndWhenResuming() async throws {
        let text = "晴天面馆（东街店）\n商品示例 ¥21.00\n实付\n¥12.34\n更多推荐\n实付 ¥35"
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x01, 0xff, 0xd9]) + Data(UUID().uuidString.utf8)
        let job = try ScreenshotInbox.save(jpeg, ocr: text)
        try await ScreenshotInbox.begin(job.id)
        let state = await ScreenshotInbox.session.state(job.id)
        let first = try XCTUnwrap(state)
        XCTAssertEqual(first.preview.amount, "12.34")
        XCTAssertEqual(first.preview.merchant, "晴天面馆(东街店)")
        _ = try await ReceiptSnippetIntent(cardID: job.id).perform()
        let paper = try await ReceiptStore.shared.snapshot(job.id)
        XCTAssertEqual(paper.draft.amount, "12.34")
        XCTAssertEqual(paper.cardID, job.id)
        XCTAssertTrue(paper.awaitingScreenshot)
        _ = try await ReceiptPanelIntent(job.id, .amount).perform()
        let editing = try await ReceiptStore.shared.snapshot(job.id)
        XCTAssertEqual(editing.panel, .amount)
        _ = try await ReceiptAmountKeyIntent(job.id, "done").perform()
        let image = try capture(paper, width: 320, name: "screenshot-full-paper-dark-320", scheme: .dark)
        XCTAssertLessThanOrEqual(image.size.height - 32, 340)
        _ = try await ContinueIndependentScreenshotIntent().perform()
        let latest = try ScreenshotInbox.latest()
        XCTAssertEqual(latest, job.id)
    }

    func testNativeVisionReadsSparseColumnsWhenShortcutTextHasNoPaidRow() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 706, height: 1120), format: format)
        let jpeg = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0,y: 0,width: 706,height: 1120))
            func draw(_ text: String, _ x: Int, _ y: Int, _ size: CGFloat = 26) {
                (text as NSString).draw(at: CGPoint(x: CGFloat(x),y: CGFloat(y)), withAttributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black])
            }
            draw("订单详情",22,36); draw("申请退款",526,90)
            draw("服务保障中",22,200); draw("号码保护",533,202)
            draw("晴天面馆（东街店）",22,366)
            draw("招牌番茄面",150,440); draw("拼单价 ¥24.00",493,440)
            draw("×1",150,505); draw("实付",22,603); draw("¥13.80",554,599,34)
            draw("配送地址",22,680); draw("更多推荐",22,844); draw("¥8.60",555,925)
        }
        let spatial = try await Task.detached { try ScreenshotImageText.rows(in: jpeg) }.value
        let bill = ScreenshotReceiptPreview(text: spatial)
        XCTAssertEqual(bill.amount, "13.80", spatial)
        let job = try ScreenshotInbox.save(jpeg, ocr: "实付\n配送地址\n拼单价 ¥24.00\n¥13.80")
        try await ScreenshotInbox.begin(job.id)
        let paper = try await ReceiptStore.shared.snapshot(job.id)
        XCTAssertEqual(paper.draft.amount, "13.80")
        XCTAssertTrue(paper.draft.merchant.contains("面馆"), spatial)
        XCTAssertTrue(paper.draft.product.contains("番茄"), spatial)
        XCTAssertEqual(paper.draft.category, "餐饮")
        let frame = try capture(paper, width: 390, name: "v7-complete-local-receipt-390")
        XCTAssertLessThanOrEqual(frame.size.height - 32, 340)
        for (i, progress) in [0.0, 0.5, 1.0].enumerated() {
            var pose = paper
            pose.motion = .printing; pose.continuousFeed = true; pose.paperProgress = progress
            _ = try capture(pose, width: 390, name: "v7-native-feed-390-" + String(i))
        }
    }

    func testMarketplaceWalletAndBankReachTheFirstPaperBeforeTheServerResponds() async throws {
        struct Example {
            let rows: [(String, Int, Int)]
            let amount: String
            let shop: String
            let category: String
        }
        let examples = [
            Example(rows: [("拼多多",30,50),("订单详情",30,125),("纸舟日用官方旗舰店",30,260),("云纹抽纸",125,365),("拼单价 ¥32.90",465,365),("实付款",30,515),("¥22.90",520,515),("更多推荐",30,700)],amount:"22.90",shop:"旗舰店",category:"购物"),
            Example(rows: [("微信支付",30,50),("账单详情",30,125),("-18.60",280,230),("当前状态",30,350),("支付成功",430,350),("商户全称",30,450),("星舟茶饮",425,450),("商品说明",30,560),("青茶一杯",420,560),("付款方式",30,675),("零钱",440,675)],amount:"18.60",shop:"茶饮",category:"餐饮"),
            Example(rows: [("招商银行",30,50),("交易详情",30,125),("支出金额",30,260),("¥12.80",485,260),("账户余额",30,365),("¥9987.20",465,365),("对方户名",30,500),("城南地铁",420,500),("交易摘要",30,620),("乘车扣费",420,620)],amount:"12.80",shop:"地铁",category:"交通")
        ]
        for sample in examples {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let size = CGSize(width: 706, height: 850)
            let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.9) { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black]
                for (label,x,y) in sample.rows { (label as NSString).draw(at: CGPoint(x: CGFloat(x), y: CGFloat(y)), withAttributes: attributes) }
            }
            let id = try ScreenshotInbox.save(jpeg, ocr: "账单详情")
            try await ScreenshotInbox.begin(id.id)
            let paper = try await ReceiptStore.shared.snapshot(id.id)
            XCTAssertEqual(paper.draft.amount, sample.amount)
            XCTAssertTrue(paper.draft.merchant.contains(sample.shop), paper.draft.merchant)
            XCTAssertEqual(paper.draft.category, sample.category)
            XCTAssertTrue(paper.awaitingScreenshot)
        }
    }

    func testVisibleScreenshotPaperMovesOverTimeOnTheRenderingHost() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "The device explicitly requests a stationary paper")
        let store = ReceiptStore.shared, id = UUID().uuidString
        let preview = ScreenshotReceiptPreview(text: "晴天面馆（东街店）\n招牌番茄面 拼单价 ¥24.00\n实付 ¥13.80")
        await store.openScreenshot(id, preview: preview, captured: Date(timeIntervalSince1970: 1_795_418_400))
        let intro = try await ReceiptSnippetIntent.openScreenshot(id)
        let model = HostedPaperModel(try await store.snapshot(id))
        let host = UIHostingController(rootView: HostedPaper(model: model))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        let previousWindow = window.windowScene?.keyWindow
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 330), format: format)
        let clock = ContinuousClock(), start = clock.now
        await ReceiptMotionDriver.presentScreenshot(id, generation: intro.revision, sound: { _ in }, host: {
            if let next = try? await store.snapshot(id) { await model.show(next) }
        })
        var frames: [UIImage] = []
        for index in 0...45 {
            try await clock.sleep(until: start.advanced(by: .seconds(Double(index) / 15)))
            frames.append(renderer.image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            })
        }
        // Sample the rendered color, not the model progress. A sudden swap from blank to full fails.
        func paperPixels(_ image: UIImage) throws -> Int {
            let cg = try XCTUnwrap(image.cgImage)
            let count = cg.width * cg.height
            var rgba = [UInt8](repeating: 0, count: count * 4)
            return try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let colors = bytes.bindMemory(to: UInt8.self)
                var matched = 0
                for i in stride(from: 0, to: count * 4, by: 4) {
                    let r = Int(colors[i]), g = Int(colors[i+1]), b = Int(colors[i+2])
                    if r > 200, g > 180, r > b + 11, g > b + 5 { matched += 1 }
                }
                return matched
            }
        }
        let initial = try paperPixels(frames[0]), middle = try paperPixels(frames[18]), end = try paperPixels(frames[45])
        for (index,image) in frames.enumerated() {
            let attachment = XCTAttachment(image: image)
            attachment.name = String(format: "v7-visible-feed-%03d", index)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThan(end - initial, 8_000, "The full paper must emerge into the host")
        XCTAssertGreaterThan(middle, initial + (end - initial) / 10)
        XCTAssertLessThan(middle, end - (end - initial) / 10)
    }

    func testFirstPresentationPlaysOneFeedPerOpenAndNeverOnRepeatedRendering() async throws {
        actor Probe {
            var sounds: [ReceiptMotion] = []
            var reloads = 0
            func play(_ motion: ReceiptMotion) { sounds.append(motion) }
            func refresh() { reloads += 1 }
        }
        let probe = Probe(), store = ReceiptStore.shared
        let id = UUID().uuidString
        await store.openScreenshot(id, preview: ScreenshotReceiptPreview(text: "实付 13.80"), captured: Date())
        let intro = try await ReceiptSnippetIntent.openScreenshot(id)
        let initial = try await store.snapshot(id)
        XCTAssertEqual(initial.motion, .printing)
        XCTAssertEqual(initial.paperProgress, 0)
        for _ in 0..<3 {
            await ReceiptMotionDriver.presentScreenshot(id, generation: intro.revision,
                sound: { await probe.play($0) }, host: { await probe.refresh() })
        }
        try await Task.sleep(for: .milliseconds(500))
        let finished = try await store.snapshot(id)
        XCTAssertEqual(finished.paperProgress, 1)
        XCTAssertEqual(finished.motion, .idle)
        let sounds = await probe.sounds, reloads = await probe.reloads
        XCTAssertEqual(sounds, [.printing])
        XCTAssertEqual(reloads, UIAccessibility.isReduceMotionEnabled ? 0 : 1)
        let second = try await ReceiptSnippetIntent.openScreenshot(id)
        await ReceiptMotionDriver.presentScreenshot(id, generation: second.revision, inApp: true,
            sound: { await probe.play($0) }, host: { await probe.refresh() })
        try await Task.sleep(for: .milliseconds(500))
        let again = await probe.sounds, after = await probe.reloads
        XCTAssertEqual(again, [.printing, .printing])
        XCTAssertEqual(after, reloads)
    }

    func testNativePaperRendersAtPhoneWidths() async throws {
        let id = try await ReceiptStore.shared.demo()
        let ready = try await ReceiptStore.shared.snapshot(id)
        for width in [320.0, 390.0, 430.0] {
            let compact = try capture(ready, width: width, name: "ready-\(Int(width))")
            XCTAssertLessThanOrEqual(compact.size.height - 32, 340, "Receipt including footer must fit the compact snippet content budget")
            for kind in [TransactionKind.income, .transfer, .refund] {
                var variant = ready
                variant.draft.transactionType = kind
                variant.draft.category = kind.categories.first ?? ""
                variant.draft.receiptAccount = "微信零钱"
                let image = try capture(variant, width: width, name: "compact-\(kind.rawValue)-\(Int(width))")
                XCTAssertLessThanOrEqual(image.size.height - 32, 340, "All default transaction kinds should fit without scrolling")
            }
        }
        let compact = try capture(ready, width: 390, name: "compact-summary-390")
        _ = try await ReceiptPanelIntent(id, .category).perform()
        let expanded = try capture(try await ReceiptStore.shared.snapshot(id), width: 390, name: "category-390")
        XCTAssertLessThanOrEqual(expanded.size.height - 32, 340, "Expanded choices must fit by collapsing unrelated details")
        _ = try await ReceiptInlineChoiceIntent(id, .category, "购物").perform()
        let selected = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(selected.cardID, id); XCTAssertEqual(selected.panel, .summary)
        let collapsed = try capture(selected, width: 390, name: "selected-category-collapsed-390")
        XCTAssertEqual(collapsed.size.height, compact.size.height, accuracy: 1)
        _ = try await ReceiptPanelIntent(id, .account).perform()
        try capture(try await ReceiptStore.shared.snapshot(id), width: 320, name: "account-expanded-320")
        _ = try await ReceiptInlineChoiceIntent(id, .account, "银行卡").perform()
        _ = try await ReceiptTextActionIntent(id, "open", "budgetMonth").perform()
        try capture(try await ReceiptStore.shared.snapshot(id), width: 320, name: "budget-expanded-320")
        _ = try await ReceiptTextActionIntent(id, "cancel").perform()
        try await ReceiptStore.shared.confirm(id)
        try capture(try await ReceiptStore.shared.snapshot(id), width: 390, name: "confirmed-390")
    }

    func testPaperStaysReadableInDarkHostAndAmountUsesSameSnippet() async throws {
        let id = try await ReceiptStore.shared.demo()
        let ready = try await ReceiptStore.shared.snapshot(id)
        let light = try capture(ready, width: 390, name: "paper-light-390", scheme: .light)
        let dark = try capture(ready, width: 390, name: "paper-dark-host-390", scheme: .dark)
        // Same fixed outer background isolates light/dark changes inside the paper.
        // A semantic white foreground on the warm paper must fail this regression.
        XCTAssertEqual(light.pngData(), dark.pngData(), "Paper ink must not inherit host dark-mode white")
        _ = try await ReceiptPanelIntent(id, .amount).perform()
        for key in ["4", "8", ".", "5"] { _ = try await ReceiptAmountKeyIntent(id, key).perform() }
        var s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.panel, .amount)
        XCTAssertEqual(s.amountInput, "48.5"); XCTAssertEqual(s.draft.amount, "23.00")
        for width in [320.0, 390.0, 430.0] {
            let image = try capture(s, width: width, name: "keypad-dark-\(Int(width))", scheme: .dark)
            let normal = try capture(ready, width: width, name: "compact-ready-\(Int(width))", scheme: .dark)
            XCTAssertLessThanOrEqual(image.size.height - 32, 340, "The active keypad must fit inside the same receipt")
            XCTAssertNotEqual(image.pngData(), normal.pngData())
        }
        _ = try await ReceiptAmountKeyIntent(id, "done").perform()
        s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.panel, .summary); XCTAssertEqual(s.draft.amount, "48.50")
        try capture(s, width: 390, name: "amount-returned-same-card", scheme: .dark)
    }

    func testFocusedEditorsFitWithoutAppendingTheWholeBill() async throws {
        let id = try await ReceiptStore.shared.demo()
        let ready = try await ReceiptStore.shared.snapshot(id)
        for width in [320.0, 390.0, 430.0] {
            for panel in [ReceiptPanel.category, .account, .destination] {
                _ = try await ReceiptPanelIntent(id, panel).perform()
                let s = try await ReceiptStore.shared.snapshot(id)
                XCTAssertEqual(s.cardID, id)
                let image = try capture(s, width: width, name: "focused-\(panel.rawValue)-\(Int(width))")
                XCTAssertLessThanOrEqual(image.size.height - 32, 340)
            }
            for field in ["product", "merchant", "note", "account", "destination", "date", "budgetMonth", "order"] {
                _ = try await ReceiptTextActionIntent(id, "open", field).perform()
                let s = try await ReceiptStore.shared.snapshot(id)
                XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.inlineEditor, field)
                let image = try capture(s, width: width, name: "focused-\(field)-\(Int(width))")
                XCTAssertLessThanOrEqual(image.size.height - 32, 340, field)
                if !["date", "budgetMonth"].contains(field) {
                    var long = s
                    long.textInput = String(repeating: "测试长文本", count: 25)
                    for mode in [ReceiptKeyboardMode.pinyin, .english, .numbers] {
                        long.keyboardMode = mode
                        long.pinyinInput = mode == .pinyin ? "wancan" : ""
                        let keyed = try capture(long, width: width, name: "focused-\(field)-\(mode.rawValue)-\(Int(width))")
                        XCTAssertLessThanOrEqual(keyed.size.height - 32, 340, "Long text and all 26-key modes must stay bounded")
                    }
                }
                _ = try await ReceiptTextActionIntent(id, "cancel").perform()
            }
            var refund = ready
            refund.draft.transactionType = .refund; refund.panel = .refunds
            let data = Data(#"{"candidates":[{"id":"one","occurredAt":"2026-11-13T12:00","amount":"30.00","remainingAmount":"25.00","merchant":"示例商户","product":"示例商品","paymentAccount":"微信零钱"},{"id":"two","occurredAt":"2026-11-13T12:00","amount":"30.00","remainingAmount":"25.00","merchant":"示例商户","product":"示例商品","paymentAccount":"微信零钱"},{"id":"three","occurredAt":"2026-11-13T12:00","amount":"30.00","remainingAmount":"25.00","merchant":"示例商户","product":"示例商品","paymentAccount":"微信零钱"},{"id":"four","occurredAt":"2026-11-13T12:00","amount":"30.00","remainingAmount":"25.00","merchant":"示例商户","product":"示例商品","paymentAccount":"微信零钱"}]}"#.utf8)
            refund.draft.refundMatch = try JSONDecoder().decode(RefundMatches.self, from: data)
            for page in [0, 1, 100] {
                refund.page = page
                let image = try capture(refund, width: width, name: "focused-refunds-\(page)-\(Int(width))")
                XCTAssertLessThanOrEqual(image.size.height - 32, 340)
            }
        }
        let restored = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(restored.cardID, id); XCTAssertEqual(restored.draft.amount, ready.draft.amount)
        XCTAssertEqual(restored.panel, .summary); XCTAssertNil(restored.inlineEditor)
        XCTAssertEqual(restored.phase, .ready)
    }

    func testNativePaperFeedAndTearFrames() async throws {
        let id = try await ReceiptStore.shared.demo()
        let maybeGeneration = try await ReceiptStore.shared.beginMotion(id, .printing)
        let generation = try XCTUnwrap(maybeGeneration)
        var reservedHeight: CGFloat?
        var fixedPrinter: Data?
        for progress in [0.125, 0.5, 1.0] {
            try await ReceiptStore.shared.advanceMotion(id, generation: generation, progress: progress)
            let image = try capture(try await ReceiptStore.shared.snapshot(id), width: 390, name: "feed-\(Int(progress * 100))")
            if let reservedHeight { XCTAssertEqual(image.size.height, reservedHeight, accuracy: 0.01, "Keep the printer's host frame fixed while feeding") }
            reservedHeight = image.size.height
            let pixels = try XCTUnwrap(image.cgImage)
            let printer = try XCTUnwrap(pixels.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(pixels.width), height: 30 * image.scale)))
            let data = try XCTUnwrap(UIImage(cgImage: printer).pngData())
            if let fixedPrinter { XCTAssertEqual(data, fixedPrinter, "Printer aperture must not move between feed frames") }
            fixedPrinter = data
        }
        try await ReceiptStore.shared.confirm(id)
        let maybeTear = try await ReceiptStore.shared.beginMotion(id, .tearing)
        let tear = try XCTUnwrap(maybeTear)
        for progress in [0.175, 0.30, 0.50, 0.75] {
            try await ReceiptStore.shared.advanceMotion(id, generation: tear, progress: progress, completing: false)
            try capture(try await ReceiptStore.shared.snapshot(id), width: 390, name: "tear-\(Int(progress * 100))")
        }
        try await ReceiptStore.shared.advanceMotion(id, generation: tear, progress: 1)
        try capture(try await ReceiptStore.shared.snapshot(id), width: 390, name: "torn-confirmed")
    }

    func testEveryEditableFieldUsesSameCardAndConfirmationAwaitsTear() async throws {
        let id = try await ReceiptStore.shared.demo()
        for field in [ReceiptField.product, .merchant, .note, .account, .destination, .date, .budgetMonth] {
            _ = try await ReceiptEditIntent(id, field).perform()
            let s = try await ReceiptStore.shared.snapshot(id)
            XCTAssertEqual(s.cardID, id)
            XCTAssertEqual(s.inlineEditor, field == .budgetMonth ? "date" : field.rawValue)
            _ = try await ReceiptTextActionIntent(id, "cancel").perform()
        }
        _ = try await ReceiptOrderIntent(id).perform()
        var s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.inlineEditor, "order")
        _ = try await ReceiptTextActionIntent(id, "cancel").perform()
        _ = try await ReceiptNoteIntent(id, "工作报销").perform()
        _ = try await ReceiptInlineChoiceIntent(id, .category, "购物").perform()
        _ = try await ReceiptDateAdjustIntent(id, "day", -1).perform()
        s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.note, "工作报销"); XCTAssertEqual(s.draft.category, "购物")
        XCTAssertEqual(s.draft.occurredAt, "2026-11-12T21:06")
        try capture(s, width: 390, name: "updated-summary-same-card")
        _ = try await ReceiptEditIntent(id, .note).perform()
        try capture(try await ReceiptStore.shared.snapshot(id), width: 320, name: "inline-note-editor-320")
        _ = try await ReceiptTextActionIntent(id, "cancel").perform()
        _ = try await ReceiptEditIntent(id, .date).perform()
        try capture(try await ReceiptStore.shared.snapshot(id), width: 320, name: "inline-date-editor-320")
        _ = try await ReceiptTextActionIntent(id, "cancel").perform()
        let start = Date()
        let confirmation = Task { _ = try await ReceiptConfirmIntent(id).perform() }
        if !UIAccessibility.isReduceMotionEnabled {
            try await Task.sleep(for: .milliseconds(200))
            s = try await ReceiptStore.shared.snapshot(id)
            XCTAssertEqual(s.phase, .saved); XCTAssertEqual(s.motion, .tearing)
        }
        try await confirmation.value
        if !UIAccessibility.isReduceMotionEnabled { XCTAssertGreaterThan(Date().timeIntervalSince(start), ReceiptMotionTiming.tearDuration) }
        s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.phase, .saved); XCTAssertEqual(s.motion, .idle)
    }

    func testSavingSuccessAndUncertainResultHaveDistinctReceipts() async throws {
        let id = try await ReceiptStore.shared.demo()
        var s = try await ReceiptStore.shared.snapshot(id)
        s.isDemo = false
        var images: [Data] = []
        for phase in [ReceiptPhase.saving, .saved, .uncertain] {
            s.phase = phase
            let image = try capture(s, width: 320, name: "save-status-\(phase.rawValue)-320")
            XCTAssertLessThanOrEqual(image.size.height - 32, 340)
            images.append(try XCTUnwrap(image.pngData()))
        }
        XCTAssertNotEqual(images[0], images[1]); XCTAssertNotEqual(images[1], images[2])
        s.phase = .ready; s.message = "请选择分类。"
        try capture(s, width: 320, name: "validation-notice-at-top-320")
    }

    func testChineseKeyboardIntentsComposeAndApplyWithinSameReceipt() async throws {
        let id = try await ReceiptStore.shared.demo()
        _ = try await ReceiptTextActionIntent(id, "open", "note").perform()
        var s = try await ReceiptStore.shared.snapshot(id)
        for letter in "wancan" {
            _ = try await ReceiptKeyboardIntent(s, "key", String(letter)).perform()
            s = try await ReceiptStore.shared.snapshot(id)
        }
        XCTAssertEqual(s.pinyinInput, "wancan"); XCTAssertEqual(s.cardID, id)
        for width in [320.0, 390.0, 430.0] {
            let image = try capture(s, width: width, name: "pinyin-wancan-\(Int(width))")
            XCTAssertLessThanOrEqual(image.size.height - 32, 340)
        }
        let choice = try XCTUnwrap(s.pinyinCandidates.first { $0.text == "晚餐" })
        _ = try await ReceiptPinyinChoiceIntent(s, choice).perform()
        s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.textInput, "晚餐"); XCTAssertEqual(s.note, "")
        _ = try await ReceiptTextActionIntent(id, "done").perform()
        s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.note, "晚餐"); XCTAssertNil(s.inlineEditor); XCTAssertEqual(s.cardID, id)
        XCTAssertEqual(s.phase, .ready)
    }

    func testTearRefreshesOnlyStartAndTargetAndDoesNotPublishSuccessEarly() async throws {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let id = try await ReceiptStore.shared.demo()
        try await ReceiptStore.shared.confirm(id, prepareTear: true)
        let probe = MotionRefreshProbe()
        let start = ContinuousClock.now
        await ReceiptMotionDriver.start(id, motion: .tearing, refresh: {
            if let s = try? await ReceiptStore.shared.snapshot(id) { await probe.record(s) }
        })
        let frames = await probe.frames()
        XCTAssertEqual(frames.count, 2, "Only the starting pose and interpolated target; no duplicate final reload")
        XCTAssertEqual(frames.map(\.paperProgress), [0, 1])
        XCTAssertTrue(frames.allSatisfy { $0.cardID == id && !$0.showsCompletion && $0.motion == .tearing })
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(ReceiptMotionTiming.tearDuration))
        let final = try await ReceiptStore.shared.snapshot(id)
        XCTAssertTrue(final.showsCompletion); XCTAssertEqual(final.cardID, id)
        await ReceiptMotionDriver.start(id, motion: .tearing, refresh: { await probe.record(final) })
        let afterDuplicate = await probe.frames()
        XCTAssertEqual(afterDuplicate.count, 2, "A finished receipt cannot replay its tear")
    }

    func testUndoButtonReturnsEditableReceiptWithoutNavigationOrOversizedCard() async throws {
        let id = try await ReceiptStore.shared.demo()
        try await ReceiptStore.shared.confirm(id)
        var s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertTrue(s.canUndo)
        let saved = try capture(s, width: 320, name: "saved-with-undo-320")
        XCTAssertLessThanOrEqual(saved.size.height - 32, 340)
        _ = try await ReceiptUndoIntent(id).perform()
        s = try await ReceiptStore.shared.snapshot(id)
        XCTAssertEqual(s.cardID, id); XCTAssertEqual(s.phase, .ready); XCTAssertTrue(s.undoRestored)
        let restored = try capture(s, width: 320, name: "undo-restored-same-card-320")
        XCTAssertLessThanOrEqual(restored.size.height - 32, 340)
        _ = try await ReceiptPanelIntent(id, .amount).perform()
        _ = try await ReceiptAmountKeyIntent(id, "4").perform()
        _ = try await ReceiptAmountKeyIntent(id, "done").perform()
        s = try await ReceiptStore.shared.snapshot(id); XCTAssertEqual(s.draft.amount, "4.00")
    }

    @discardableResult private func capture(_ snapshot: ReceiptSnapshot, width: Double, name: String, scheme: ColorScheme = .light) throws -> UIImage {
        let content = ReceiptSnippetView(snapshot: snapshot)
            .frame(width: width - 32).padding(16)
            .background(Color(red: 0.94, green: 0.93, blue: 0.96))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "Native card must produce an image")
        XCTAssertGreaterThan(image.size.height, 20)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}

@MainActor private final class HostedPaperModel: ObservableObject {
    @Published private(set) var paper: ReceiptSnapshot
    init(_ paper: ReceiptSnapshot) { self.paper = paper }
    func show(_ paper: ReceiptSnapshot) { self.paper = paper }
}

private struct HostedPaper: View {
    @ObservedObject var model: HostedPaperModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.94, green: 0.93, blue: 0.96)
            ReceiptSnippetView(snapshot: model.paper).frame(width: 358).padding(16)
        }.ignoresSafeArea()
    }
}

private actor MotionRefreshProbe {
    private var values: [ReceiptSnapshot] = []
    func record(_ value: ReceiptSnapshot) { values.append(value) }
    func frames() -> [ReceiptSnapshot] { values }
}
