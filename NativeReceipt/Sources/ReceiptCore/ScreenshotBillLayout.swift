import Foundation

/// Visible labels establish the page family. A payment method printed on a shop order
/// identifies the payment channel, not the app that displayed the order.
struct ScreenshotBillLayout {
    enum Family { case order, wallet, bank, other }
    let lines: [String]
    let compact: [String]
    let family: Family
    let platform: String?

    private static let stores = ["拼多多", "天猫", "淘宝", "京东", "美团", "拼好饭", "饿了么", "淘宝闪购", "抖音商城", "快手小店", "唯品会"]
    private static let banks = ["中国工商银行", "工商银行", "中国建设银行", "建设银行", "中国农业银行", "农业银行", "中国银行", "招商银行", "交通银行", "中国邮政储蓄银行", "邮储银行", "中信银行", "浦发银行", "平安银行", "兴业银行", "民生银行", "光大银行"]
    private static let wallets = ["微信支付", "支付宝", "云闪付"]
    private static let recommendations = ["更多推荐", "猜你喜欢", "为你推荐", "为您推荐", "相关推荐", "看了又看", "你可能还喜欢"]
    private static let headerDecorations = CharacterSet(charactersIn: " 〈〉<>›»❯〈·|｜：:")
    private static let metadata = ["支付时间", "付款时间", "交易时间", "下单时间", "创建时间", "订单编号", "订单号", "交易单号", "商户单号", "支付方式", "付款方式", "收货地址", "配送地址", "联系电话", "发票信息", "物流信息", "实付", "商品金额", "优惠", "运费", "拼单价", "合计", "交易状态", "当前状态", "到账时间", "对方账号", "银行卡号", "账户余额", "可用余额"]
    private static let blacklist = ["号码保护", "退货包运费", "极速退款", "退款/售后", "申请售后", "申请退款", "联系商家", "联系卖家", "查看物流", "再次购买", "订单详情", "交易详情", "账单详情", "商品详情", "交易成功", "支付成功", "商家服务", "点击查看", "已拼单", "配送中", "选择规格", "进入店铺", "进店逛逛", "进店"]
    private static let unsafeText = try! NSRegularExpression(pattern: #"\*{2,}|1[3-9]\d{9}|\d{12,}|收货地址|配送地址|联系电话|号楼|单元|门牌"#)
    private static let shopTitle = try! NSRegularExpression(pattern: #"^(?:[^¥￥:：|｜]{2,46}\s*\([^()]{1,18}店\)|[^¥￥:：|｜]{1,39}(?:旗舰店|专营店|专卖店|自营店|品牌店|官方店|折扣店|百货店))$"#)
    private static let productTail = try! NSRegularExpression(pattern: #"\s*(?:(?:拼单价|单价|原价|券后价|售价|到手价)\s*[:：]?\s*[¥￥]?\s*\d|[¥￥]\s*\d|[xX×]\s*\d+\s*$).*$"#)
    private static let addressDigits = try! NSRegularExpression(pattern: #"\d{4,}"#)

    init(_ text: String) {
        let normalized = String(text.prefix(8000)).folding(options: .widthInsensitive, locale: nil)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        let all = normalized.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let rows = Array(all.prefix { row in
            let value = Self.squeeze(row).trimmingCharacters(in: Self.headerDecorations.union(.symbols))
            return !Self.recommendations.contains(where: value.hasPrefix)
        })
        lines = rows
        let compact = rows.map(Self.squeeze)
        self.compact = compact
        let first = Array(compact.prefix(12))
        let store = Self.headerBrand(Self.stores, first)
        let bank = Self.headerBrand(Self.banks, first)
        let wallet = Self.headerBrand(Self.wallets, first)
        let bankLabels = ["对方户名", "对方户名/名称", "借贷标志", "借贷方向", "交易后余额", "账户余额", "可用余额", "对手户名", "对方户名或商户"]
        let brands: [(found: (index: Int, name: String)?, family: Family)] = [(store, .order), (bank, .bank), (wallet, .wallet)]
        if let brand = brands.compactMap({ entry in entry.found.map { (index: $0.index, name: $0.name, family: entry.family) } }).min(by: { $0.index < $1.index }) {
            family = brand.family; platform = brand.name
        } else if bankLabels.filter({ label in compact.contains(where: { $0.hasPrefix(label) }) }).count >= 2 {
            family = .bank; platform = nil
        } else if compact.contains(where: { $0.contains("商户全称") || $0.hasPrefix("收钱码") }) ||
                    (compact.contains(where: { $0.contains("账单详情") }) && compact.contains(where: { $0.hasPrefix("付款方式") || $0.hasPrefix("支付方式") || $0.hasPrefix("交易单号") })) {
            family = .wallet; platform = nil
        } else if compact.contains(where: { $0.contains("拼单价") || $0.contains("订单详情") || $0.hasPrefix("实付") || $0.hasPrefix("实际支付") }) {
            family = .order; platform = nil
        } else {
            family = .other; platform = nil
        }
    }

    static func squeeze(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func headerBrand(_ names: [String], _ rows: [String]) -> (index: Int, name: String)? {
        let suffixes = ["支付账单", "账单详情", "账单", "支付凭证", "订单详情", "交易详情", "交易明细", "收支明细", "手机银行", "App", "APP", "官方客服", "收款助手", "支付结果", "购物"]
        for (i, row) in rows.enumerated() {
            if i > 0 && ["支付方式","付款方式","支付渠道","付款银行","商户全称","商户名称","商品说明","资金来源"].contains(rows[i-1].trimmingCharacters(in: headerDecorations)) { continue }
            let title = row.trimmingCharacters(in: headerDecorations)
            if let brand = names.first(where: { name in title == name || suffixes.contains(where: { title == name + $0 }) }) { return (i, brand) }
        }
        return nil
    }

    /// Prefer explicitly labeled fields. A following row is eligible only when the label occupies its own row.
    func field(_ labels: [String]) -> String? {
        for label in labels {
            for (i, line) in lines.enumerated() {
                if compact[i].trimmingCharacters(in: Self.headerDecorations) == label {
                    if i + 1 < lines.count, let v = Self.clean(lines[i + 1]) { return v }
                } else if line.hasPrefix(label) {
                    let rest = line.dropFirst(label.count)
                    if let first = rest.first, first.isWhitespace || ":：|｜".contains(first),
                       let v = Self.clean(String(rest).trimmingCharacters(in: Self.headerDecorations)) { return v }
                }
            }
        }
        return nil
    }

    private static func clean(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: headerDecorations), tight = squeeze(v)
        guard (1...72).contains(v.count), !metadata.contains(where: tight.hasPrefix), !blacklist.contains(tight),
              !matches(unsafeText, v), !v.contains("¥"), v.rangeOfCharacter(from: .letters) != nil else { return nil }
        return v
    }

    func merchant(near headline: Int?) -> (name: String, index: Int?)? {
        var labels = ["商户全称", "商户名称", "商家名称", "店铺名称", "商家", "商户", "收款商户"]
        if family == .wallet || family == .bank { labels += ["交易商户", "商户简称", "对方户名", "对手户名", "收款方名称", "收款单位", "收款方", "付款方名称", "付款方", "交易对方", "对方名称"] }
        if let title = field(labels) { return (title, lines.firstIndex(where: { $0.contains(title) })) }
        if family == .wallet, let headline, headline > 0, let value = Self.clean(lines[headline-1]), value != platform,
           !["支出", "收入", "已完成", "交易成功", "账单详情"].contains(value) { return (value, headline-1) }
        guard family == .order || family == .other else { return nil }
        var candidates: [(String, Int)] = []
        for (i,line) in lines.enumerated() {
            var title = line.trimmingCharacters(in: Self.headerDecorations)
            for tail in ["进入店铺", "进店逛逛", "进店", "关注店铺"] where title.hasSuffix(tail) {
                title = String(title.dropLast(tail.count)).trimmingCharacters(in: Self.headerDecorations)
            }
            guard let name = Self.clean(title), !Self.matches(Self.addressDigits, name) else { continue }
            let isShop = Self.matches(Self.shopTitle, name)
            let withEntry = ["进入店铺", "进店逛逛", "进店"].contains(where: line.hasSuffix) && title != line
            if isShop || withEntry { candidates.append((name,i)) }
        }
        guard let first = candidates.first, candidates.allSatisfy({ $0.0 == first.0 }) else { return nil }
        return first
    }

    func product(after shop: Int?) -> String? {
        if let value = field(["商品说明", "商品名称", "商品标题", "商品", "交易说明", "交易摘要", "摘要", "交易备注", "用途"]) { return value }
        guard family == .order || family == .other else { return nil }
        if shop == nil {
            let named = lines.compactMap { line -> String? in
                guard ["拼单价", "单价", "券后价"].contains(where: line.contains),
                      let range = Self.productTail.firstMatch(in: line, range: NSRange(line.startIndex...,in:line))?.range,
                      let r = Range(range, in: line), let name = Self.clean(String(line[..<r.lowerBound])) else { return nil }
                return name
            }
            return Set(named).count == 1 ? named.first : nil
        }
        guard let shop, shop + 1 < lines.count else { return nil }
        for i in (shop + 1)..<min(shop + 7, lines.count) {
            let row = lines[i]
            if Self.metadata.contains(where: compact[i].hasPrefix) { break }
            let raw = Self.productTail.stringByReplacingMatches(in: row, range: NSRange(row.startIndex...,in:row), withTemplate: "")
            if let name = Self.clean(raw), (2...60).contains(name.count), !Self.blacklist.contains(where: name.hasPrefix),
               !name.hasPrefix("规格"), !name.hasPrefix("数量"), !Self.matches(Self.shopTitle, name) { return name }
        }
        return nil
    }

    static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    func account() -> String? {
        guard let raw = field(["付款方式", "支付方式", "资金来源", "付款账户", "到账方式", "收款方式"]) else { return nil }
        if raw.contains("零钱通") { return "零钱通" }
        if raw.contains("零钱") { return "微信零钱" }
        if raw.contains("余额宝") { return "余额宝" }
        if raw.contains("花呗") { return "花呗" }
        if raw.contains("支付宝余额") || (raw == "余额" && platform == "支付宝") { return "支付宝余额" }
        if ["银行卡", "储蓄卡", "借记卡", "信用卡"].contains(where: raw.contains) { return "银行卡" }
        return raw == "现金" ? "现金" : nil
    }

    func category(merchant: String?, product: String?, type: TransactionKind) -> String? {
        let information = [merchant, product].compactMap { $0 }.joined(separator: " ")
        if type == .refund { return "退款" }
        if type == .transfer { return "转账" }
        if type == .income { return information.contains("工资") || information.contains("薪资") ? "工资" : nil }
        guard type == .expense || (family == .order && type == .unknown) else { return nil }
        let rules: [(String, [String])] = [
            ("宠物", ["猫粮","狗粮","猫砂","宠物","猫条"]),
            ("医疗", ["药房","药店","药品","医院","诊所","挂号"]),
            ("交通", ["地铁","公交","打车","出租车","停车费","加油站","网约车"]),
            ("通讯", ["话费","流量包","宽带费","电信营业厅","移动营业厅"]),
            ("餐饮", ["炒粉","米粉","炒饭","面馆","餐厅","奶茶","快餐","汉堡","米线","烧烤","水饺","饺子","咖啡店","咖啡馆","炸鸡","小吃","茶饮","外卖"]),
            ("订阅", ["会员续费","月度会员","自动续费","云存储"]),
            ("购物", ["超市","百货","旗舰店","专营店","专卖店","自营店","便利店"])
        ]
        if let result = rules.first(where: { $0.1.contains(where: information.contains) }) { return result.0 }
        if family == .order, let platform, ["拼多多","淘宝","天猫","京东","唯品会","抖音商城","快手小店"].contains(platform), product != nil { return "购物" }
        return nil
    }
}
