import AppIntents
import SwiftUI
import ReceiptCore

// The system host can be dark while the physical paper stays warm and light.
// Never use semantic primary/secondary foreground colors on this paper.
enum PaperStyle {
    static let ink = Color(red: 0.20, green: 0.17, blue: 0.24)
    static let secondary = Color(red: 0.43, green: 0.38, blue: 0.43)
    static let violet = Color(red: 0.43, green: 0.32, blue: 0.61)
    static let paper = Color(red: 0.955, green: 0.922, blue: 0.860)
    static let chip = Color(red: 0.89, green: 0.85, blue: 0.94)
    static let line = Color(red: 0.68, green: 0.61, blue: 0.54)
}

struct ReceiptSnippetView: View {
    let snapshot: ReceiptSnapshot?
    var inApp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let s = snapshot {
                let tear = s.motion == .tearing && !reduceMotion ? s.paperProgress : 0
                VStack(spacing: 0) {
                    printerSlot
                    ZStack(alignment: .top) {
                        if s.motion == .tearing {
                            ReceiptPaper().fill(PaperStyle.paper).frame(height: 13)
                        }
                        PaperFeedLayout(progress: s.motion == .printing && !reduceMotion ? s.paperProgress : 1) {
                            paper(s)
                                .modifier(ReceiptTearEffect(progress: tear))
                        }
                        .clipped()
                    }
                    .padding(.horizontal, 4)
                }
                .foregroundStyle(PaperStyle.ink)
                .tint(PaperStyle.violet)
                .environment(\.colorScheme, .light)
                .animation(reduceMotion ? nil : .linear(duration: s.motion == .tearing ? ReceiptMotionTiming.tearDuration : s.continuousFeed ? ReceiptMotionTiming.feedDuration : 0.24), value: s.paperProgress)
            } else {
                Label("小票已关闭，请重新运行截图记账。", systemImage: "receipt")
                    .font(.callout).padding()
            }
        }
    }

    private var printerSlot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.78, green: 0.75, blue: 0.83))
            Capsule().fill(Color(red: 0.23, green: 0.20, blue: 0.28))
                .frame(height: 5).padding(.horizontal, 9)
                .overlay(alignment: .top) { Capsule().fill(.white.opacity(0.35)).frame(height: 1).padding(.horizontal, 10) }
        }
        .frame(height: 14).padding(.horizontal, 1)
        .accessibilityHidden(true)
    }

    private func paper(_ s: ReceiptSnapshot) -> some View {
        VStack(spacing: 8) {
            if !isTextEditing(s) { header(s) }
            if s.showsCompletion {
                completion(s)
            } else if s.phase == .saving || s.phase == .uncertain {
                saveStatus(s)
            } else {
                if !s.message.isEmpty && s.panel != .amount && !isTextEditing(s) {
                    Label(s.message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.58, green: 0.24, blue: 0.20))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if isEditing(s) {
                    focusedEditor(s)
                } else {
                    amount(s)
                    summary(s)
                    perforation
                    footer(s)
                }
            }
        }
        .padding(.horizontal, isTextEditing(s) ? 10 : 14).padding(.vertical, isTextEditing(s) ? 7 : 12)
        .modifier(PaperSurface())
    }

    private func isEditing(_ s: ReceiptSnapshot) -> Bool {
        s.inlineEditor != nil || [.amount, .category, .account, .destination, .refunds].contains(s.panel)
    }

    /// Keep the paper and card identity; lend its limited space to the active
    /// field instead of appending an editor below the complete bill.
    @ViewBuilder private func focusedEditor(_ s: ReceiptSnapshot) -> some View {
        if s.panel == .amount {
            amountEditor(s)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(editorTitle(s)).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("¥\(s.draft.amount)")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if s.inlineEditor == nil {
                        Button("收起", intent: ReceiptPanelIntent(s.cardID, .summary))
                            .font(.system(size: 12)).foregroundStyle(PaperStyle.violet)
                            .buttonStyle(.plain).padding(.leading, 4)
                    }
                }.frame(minHeight: 24)
                if let field = s.inlineEditor {
                    if field == "date" { dateEditor(s) }
                    else if field == "budgetMonth" { budgetEditor(s) }
                    else { textEditor(s, field: field) }
                } else if s.panel == .category {
                    selectionGrid(s, panel: .category, values: s.draft.transactionType.categories, selected: s.draft.category, columns: 4)
                } else if s.panel == .account || s.panel == .destination {
                    accountEditor(s, destination: s.panel == .destination)
                } else if s.panel == .refunds {
                    refundSection(s)
                }
            }.disabled(s.locked)
        }
    }

    private func editorTitle(_ s: ReceiptSnapshot) -> String {
        if let field = s.inlineEditor {
            return ["product": "修改商品", "merchant": "修改商户", "note": "修改备注", "account": "自定义账户", "destination": "自定义转入账户", "date": "修改日期", "budgetMonth": "修改预算", "order": "查找原订单"][field] ?? "修改小票"
        }
        let titles: [ReceiptPanel: String] = [.category: "选择分类", .account: "选择账户", .destination: "选择转入账户", .refunds: "选择原订单"]
        return titles[s.panel] ?? "修改小票"
    }

    private func header(_ s: ReceiptSnapshot) -> some View {
        HStack(spacing: 5) {
            Label(s.undoRestored ? "随手账 · 已撤销" : s.isDemo ? "随手账 · 体验" : "随手账", systemImage: "receipt")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(PaperStyle.violet)
            Spacer(minLength: 2)
            Button(intent: ReceiptTextActionIntent(s.cardID, "open", "date")) {
                Text(s.draft.occurredAt.replacingOccurrences(of: "T", with: " "))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(PaperStyle.secondary)
                    .padding(.vertical, 4)
            }.buttonStyle(.plain).disabled(s.locked).accessibilityLabel("修改日期，\(s.draft.occurredAt)")
            if s.panel == .summary && s.phase == .ready {
                Button(intent: ReceiptPrintIntent(s.cardID, inApp: inApp)) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 22, height: 20)
                }.buttonStyle(.plain).foregroundStyle(PaperStyle.violet)
                    .disabled(s.locked || s.inlineEditor != nil).accessibilityLabel("重播出纸")
            }
        }.lineLimit(1)
    }

    private func amount(_ s: ReceiptSnapshot) -> some View {
        Button(intent: ReceiptPanelIntent(s.cardID, .amount)) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !s.draft.amount.isEmpty { Text("¥").font(.system(size: 19, weight: .medium)) }
                Text(s.draft.amount.isEmpty ? "填写金额" : s.draft.amount).font(.system(size: 33, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.65)
                Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(PaperStyle.secondary)
                Spacer(minLength: 0)
                Image(systemName: "sparkle").font(.system(size: 18)).foregroundStyle(PaperStyle.violet.opacity(0.45))
            }.foregroundStyle(PaperStyle.ink)
        }.buttonStyle(.plain).disabled(s.locked).accessibilityLabel("修改金额，当前 \(s.draft.amount) 元")
    }

    private func amountEditor(_ s: ReceiptSnapshot) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("¥").font(.system(size: 18))
                Text(s.amountInput).font(.system(size: 31, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Text("修改金额").font(.system(size: 11)).foregroundStyle(PaperStyle.secondary)
            }.foregroundStyle(PaperStyle.ink).frame(height: 34)
            if !s.message.isEmpty {
                Text(s.message).font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.65, green: 0.20, blue: 0.21))
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            }
            Grid(horizontalSpacing: 5, verticalSpacing: 4) {
                ForEach(0..<4, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            let key = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "backspace"][row * 3 + column]
                            Button(intent: ReceiptAmountKeyIntent(s.cardID, key)) {
                                Group {
                                    if key == "backspace" { Image(systemName: "delete.left").font(.system(size: 18)) }
                                    else { Text(key).font(.system(size: 20, weight: .medium, design: .rounded)) }
                                }
                                .foregroundStyle(PaperStyle.ink).frame(maxWidth: .infinity, minHeight: 40)
                                .background(Color(red: 0.99, green: 0.97, blue: 0.93), in: RoundedRectangle(cornerRadius: 9))
                                .overlay { RoundedRectangle(cornerRadius: 9).stroke(PaperStyle.line.opacity(0.17), lineWidth: 0.6) }
                            }.buttonStyle(.plain).accessibilityLabel(key == "backspace" ? "删除一位" : key == "." ? "小数点" : key)
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                amountAction(s, "clear", "清空", prominent: false)
                amountAction(s, "cancel", "放弃修改", prominent: false)
                amountAction(s, "done", "完成", prominent: true)
            }.padding(.top, 2)
        }.disabled(s.locked)
    }

    private func amountAction(_ s: ReceiptSnapshot, _ key: String, _ label: String, prominent: Bool) -> some View {
        Button(intent: ReceiptAmountKeyIntent(s.cardID, key)) {
            Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(prominent ? Color.white : PaperStyle.violet)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(prominent ? PaperStyle.violet : PaperStyle.chip, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func summary(_ s: ReceiptSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                purchaseLine(s, field: "product", value: s.draft.product.isEmpty ? "填写商品" : s.draft.product, prominent: true)
                purchaseLine(s, field: "merchant", value: s.draft.merchant.isEmpty ? "填写商户" : s.draft.merchant, prominent: false)
            }
            perforation
            HStack(spacing: 8) {
                if s.draft.transactionType == .transfer {
                    selectionSummary(s, panel: .account, value: s.draft.account.isEmpty ? "转出账户" : s.draft.account, icon: "arrow.up.right")
                    selectionSummary(s, panel: .destination, value: s.draft.receiptAccount.isEmpty ? "转入账户" : s.draft.receiptAccount, icon: "arrow.down.left")
                } else {
                    selectionSummary(s, panel: .category, value: s.draft.category.isEmpty ? "选择分类" : s.draft.category, icon: categorySymbol(s.draft.category))
                        .frame(width: 88)
                    selectionSummary(s, panel: .account, value: s.draft.account.isEmpty ? "选择账户" : s.draft.account, icon: "creditcard")
                }
            }
            if s.panel == .category {
                selectionGrid(s, panel: .category, values: s.draft.transactionType.categories, selected: s.draft.category, columns: 4)
            }
            if s.panel == .account || s.inlineEditor == "account" { accountEditor(s, destination: false) }
            if s.panel == .destination || s.inlineEditor == "destination" { accountEditor(s, destination: true) }
            HStack(spacing: 8) {
                if s.draft.transactionType == .expense {
                    compactField(s, field: "budgetMonth", value: s.draft.budgetIncluded ? "计入预算 · \(s.draft.budgetMonth ?? String(s.draft.occurredAt.prefix(7)))" : "不计预算", icon: "checkmark.circle")
                } else if s.draft.transactionType == .refund {
                    let chosen = s.draft.refundMatch?.candidates.first { $0.id == s.draft.originalTransactionId }
                    Button(intent: ReceiptPanelIntent(s.cardID, s.panel == .refunds ? .summary : .refunds)) {
                        Label(chosen == nil ? "选择原订单" : "原订单已选", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11)).lineLimit(1).frame(minHeight: 30)
                    }.buttonStyle(.plain).foregroundStyle(PaperStyle.violet)
                }
                compactField(s, field: "note", value: s.note.isEmpty ? "添加备注" : s.note, icon: "text.alignleft")
            }
            if s.inlineEditor == "budgetMonth" { budgetEditor(s) }
            if s.inlineEditor == "note" { textEditor(s, field: "note") }
            if s.draft.transactionType == .refund && (s.panel == .refunds || s.inlineEditor == "order") { refundSection(s) }
            if s.draft.requiresManualReview {
                Label("请核对识别结果", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(PaperStyle.secondary)
            }
        }.disabled(s.locked)
    }

    private func purchaseLine(_ s: ReceiptSnapshot, field: String, value: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(intent: ReceiptTextActionIntent(s.cardID, "open", field)) {
                HStack(spacing: 7) {
                    Image(systemName: prominent ? "bag" : "storefront").font(.system(size: 11))
                    Text(value).font(.system(size: prominent ? 16 : 11, weight: prominent ? .semibold : .regular))
                        .multilineTextAlignment(.leading).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(PaperStyle.violet)
                }.foregroundStyle(prominent ? PaperStyle.ink : PaperStyle.secondary).padding(.vertical, 2)
            }.buttonStyle(.plain)
            if s.inlineEditor == field { textEditor(s, field: field) }
        }
    }

    private func compactField(_ s: ReceiptSnapshot, field: String, value: String, icon: String) -> some View {
        Button(intent: ReceiptTextActionIntent(s.cardID, "open", field)) {
            Label(value, systemImage: icon).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .foregroundStyle(PaperStyle.secondary)
        }.buttonStyle(.plain).accessibilityLabel("\(field == "note" ? "修改备注" : "修改预算")，\(value)")
    }

    private func selectionSummary(_ s: ReceiptSnapshot, panel: ReceiptPanel, value: String, icon: String) -> some View {
        Button(intent: ReceiptPanelIntent(s.cardID, s.panel == panel ? .summary : panel)) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: s.panel == panel ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(PaperStyle.violet).padding(.horizontal, 9).frame(minHeight: 36)
            .background(PaperStyle.chip.opacity(s.panel == panel ? 0.9 : 0.45), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func budgetEditor(_ s: ReceiptSnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(intent: ReceiptBudgetIntent(s.cardID)) {
                    Label(s.draft.budgetIncluded ? "计入预算" : "不计预算", systemImage: s.draft.budgetIncluded ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .medium)).frame(minHeight: 40)
                }.buttonStyle(.plain).foregroundStyle(PaperStyle.violet)
                Spacer(minLength: 0)
                dateArrow(s, "budget", -1)
                Text(s.draft.budgetMonth ?? String(s.draft.occurredAt.prefix(7))).font(.system(size: 12, design: .monospaced))
                dateArrow(s, "budget", 1)
            }
            Button("完成", intent: ReceiptTextActionIntent(s.cardID, "cancel")).font(.system(size: 12)).buttonStyle(PaperButton())
        }
    }

    private func accountEditor(_ s: ReceiptSnapshot, destination: Bool) -> some View {
        let value = destination ? s.draft.receiptAccount : s.draft.account
        let values = unique(([value] + ["微信零钱", "支付宝余额", "银行卡", "现金"]).filter { !$0.isEmpty })
        let field = destination ? "destination" : "account"
        return VStack(alignment: .leading, spacing: 9) {
            if s.inlineEditor == field { textEditor(s, field: field) }
            else {
                selectionGrid(s, panel: destination ? .destination : .account, values: values, selected: value, columns: 2)
                Button("自定义账户", intent: ReceiptTextActionIntent(s.cardID, "open", field))
                    .font(.system(size: 12)).buttonStyle(PaperButton())
            }
        }
    }

    private func selectionGrid(_ s: ReceiptSnapshot, panel: ReceiptPanel, values: [String], selected: String, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(values, id: \.self) { value in
                Button(intent: ReceiptInlineChoiceIntent(s.cardID, panel, value)) {
                    choiceLabel(value, selected: value == selected)
                }.buttonStyle(.plain)
            }
        }
    }

    private func choiceLabel(_ text: String, selected: Bool) -> some View {
        Text(text).font(.system(size: 12, weight: selected ? .semibold : .regular))
            .lineLimit(2).multilineTextAlignment(.center)
            .foregroundStyle(selected ? PaperStyle.violet : PaperStyle.ink)
            .frame(maxWidth: .infinity, minHeight: 40).padding(.horizontal, 3)
            .background(selected ? PaperStyle.chip : .white.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(selected ? PaperStyle.violet.opacity(0.42) : PaperStyle.line.opacity(0.18), lineWidth: 0.7) }
    }

    private func dateArrow(_ s: ReceiptSnapshot, _ component: String, _ offset: Int) -> some View {
        Button(intent: ReceiptDateAdjustIntent(s.cardID, component, offset)) {
            Image(systemName: offset < 0 ? "minus" : "plus").font(.system(size: 11, weight: .medium))
                .frame(width: 30, height: 32).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).foregroundStyle(PaperStyle.violet)
            .accessibilityLabel("\(component) \(offset < 0 ? "减一" : "加一")")
    }

    private func dateEditor(_ s: ReceiptSnapshot) -> some View {
        let parts = s.draft.occurredAt.components(separatedBy: CharacterSet(charactersIn: "-T:"))
        return VStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(["year", "month", "day", "hour", "minute"].enumerated()), id: \.offset) { index, component in
                    VStack(spacing: 5) {
                        Text(["年", "月", "日", "时", "分"][index]).font(.system(size: 10)).foregroundStyle(PaperStyle.secondary)
                        dateArrow(s, component, 1)
                        Text(parts.indices.contains(index) ? parts[index] : "--").font(.system(size: 13, weight: .medium, design: .monospaced))
                        dateArrow(s, component, -1)
                    }.frame(maxWidth: .infinity)
                }
            }
            Button("日期已调整", intent: ReceiptTextActionIntent(s.cardID, "cancel")).buttonStyle(PaperButton()).font(.system(size: 12))
        }.padding(10).background(.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 11))
    }

    private func textEditor(_ s: ReceiptSnapshot, field: String) -> some View {
        ReceiptKeyboardView(snapshot: s, field: field)
    }

    private func isTextEditing(_ s: ReceiptSnapshot) -> Bool {
        s.inlineEditor.map { !["date", "budgetMonth"].contains($0) } ?? false
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { seen.insert($0).inserted }
    }

    private func refundSection(_ s: ReceiptSnapshot) -> some View {
        let candidates = s.draft.refundMatch?.candidates ?? []
        let pageCount = max(1, (candidates.count + 2) / 3)
        let page = min(max(0, s.page), pageCount - 1)
        let visible = Array(candidates.dropFirst(page * 3).prefix(3))
        return VStack(alignment: .leading, spacing: 6) {
            if s.panel == .refunds {
                ForEach(visible) { candidate in
                    Button(intent: ReceiptInlineChoiceIntent(s.cardID, .refunds, candidate.id)) {
                        choiceLabel("\(candidate.product.isEmpty ? candidate.merchant : candidate.product) · 可退 ¥\(candidate.remainingAmount)", selected: candidate.id == s.draft.originalTransactionId)
                    }.buttonStyle(.plain)
                }
                if pageCount > 1 {
                    HStack {
                        Button("上一组", intent: ReceiptPanelIntent(s.cardID, .refunds, page: page - 1)).disabled(page == 0)
                        Text("\(page + 1) / \(pageCount)").frame(maxWidth: .infinity)
                        Button("下一组", intent: ReceiptPanelIntent(s.cardID, .refunds, page: page + 1)).disabled(page == pageCount - 1)
                    }.font(.system(size: 11)).buttonStyle(PaperButton(minHeight: 32))
                }
                Button("按订单号查找", intent: ReceiptTextActionIntent(s.cardID, "open", "order")).font(.system(size: 12)).buttonStyle(PaperButton())
            }
            if s.inlineEditor == "order" { textEditor(s, field: "order") }
        }
    }

    private func footer(_ s: ReceiptSnapshot) -> some View {
        HStack(spacing: 8) {
            Button("取消", intent: ReceiptCancelIntent(s.cardID)).buttonStyle(PaperButton())
            if s.panel == .amount {
                Button(intent: ReceiptAmountKeyIntent(s.cardID, "done")) { primaryActionLabel("完成修改") }.buttonStyle(.plain)
            } else if let field = s.inlineEditor {
                let immediate = field == "date" || field == "budgetMonth"
                Button(intent: ReceiptTextActionIntent(s.cardID, immediate ? "cancel" : "done")) {
                    primaryActionLabel(field == "order" ? "查找订单" : "完成修改")
                }.buttonStyle(.plain)
            } else {
                Button(intent: ReceiptConfirmIntent(s.cardID, inApp: inApp, fromLocalPaper: s.awaitingScreenshot)) { primaryActionLabel(s.isDemo ? "体验确认" : "确认记账") }.buttonStyle(.plain)
            }
        }.font(.system(size: 14, weight: .medium)).disabled(s.locked)
    }

    private func primaryActionLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").lineLimit(1)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(PaperStyle.violet, in: RoundedRectangle(cornerRadius: 12))
    }

    private func saveStatus(_ s: ReceiptSnapshot) -> some View {
        VStack(spacing: 12) {
            Image(systemName: s.phase == .saving ? "clock.arrow.circlepath" : "exclamationmark.circle")
                .font(.system(size: 30)).foregroundStyle(PaperStyle.violet)
            Text(s.phase == .saving ? "正在记账…" : "结果待确认")
                .font(.system(size: 19, weight: .semibold))
            Text("¥\(s.draft.amount)").font(.system(size: 25, weight: .semibold, design: .rounded))
            Text(s.phase == .saving ? "正在等待记账服务确认" : "连接未能确认结果，账单可能已保存。请先核对流水，避免重复记账。")
                .font(.system(size: 12)).foregroundStyle(PaperStyle.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    private func completion(_ s: ReceiptSnapshot) -> some View {
        VStack(spacing: 10) {
            if !s.message.isEmpty {
                Text(s.message).font(.system(size: 11)).foregroundStyle(PaperStyle.secondary).multilineTextAlignment(.center)
            }
            perforation
            Image(systemName: s.phase == .saved ? "checkmark.seal.fill" : "minus.circle")
                .font(.system(size: 34)).foregroundStyle(PaperStyle.violet).contentTransition(.symbolEffect(.replace))
            Text(s.phase == .undoing ? "正在撤销…" : s.phase == .undoUncertain ? "撤销待核对" : s.phase == .saved ? (s.isDemo ? "体验完成 · 未入账" : "已记账") : s.closedLocalPreview ? "本机预览已关闭" : "已取消")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(PaperStyle.ink)
            if !s.draft.amount.isEmpty {
                Text("¥\(s.draft.amount)").font(.system(size: 17, design: .monospaced)).foregroundStyle(PaperStyle.secondary)
            }
            if s.closedLocalPreview {
                Text("点「继续上张截图记账」可查看这张截图的识别结果。")
                    .font(.system(size: 12)).foregroundStyle(PaperStyle.secondary).multilineTextAlignment(.center)
            }
            if s.phase == .saved && !s.isDemo {
                Text(s.draft.product).font(.system(size: 13)).lineLimit(2)
                Text("记账服务已确认").font(.system(size: 11)).foregroundStyle(PaperStyle.secondary)
            }
            if s.canUndo {
                Button(s.phase == .undoUncertain ? "核对撤销结果" : "撤销并修改", intent: ReceiptUndoIntent(s.cardID))
                    .font(.system(size: 13, weight: .medium)).buttonStyle(PaperButton())
            }
        }.padding(.vertical, 12)
    }

    private var perforation: some View {
        Rectangle().fill(PaperStyle.line.opacity(0.4)).frame(height: 1)
            .mask { HStack(spacing: 4) { ForEach(0..<60, id: \.self) { _ in Rectangle().frame(width: 3) } } }.accessibilityHidden(true)
    }

    private func categorySymbol(_ category: String) -> String {
        ["餐饮": "fork.knife", "购物": "bag", "交通": "tram", "医疗": "cross.case", "娱乐": "film", "宠物": "pawprint", "人情": "gift", "订阅": "person.crop.rectangle", "通讯": "phone", "工作": "briefcase", "旅行": "airplane", "工资": "wallet.bifold", "奖金": "gift", "红包": "gift", "退款": "arrow.uturn.backward", "转账": "arrow.left.arrow.right"][category] ?? "receipt"
    }
}

private struct PaperButton: ButtonStyle {
    var minHeight: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(PaperStyle.violet).padding(.horizontal, 10)
            .frame(minHeight: minHeight).frame(maxWidth: .infinity)
            .background(PaperStyle.chip.opacity(configuration.isPressed ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct PaperSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
        .background {
            ReceiptPaper().fill(PaperStyle.paper)
            LinearGradient(colors: [.white.opacity(0.16), .clear, Color.brown.opacity(0.045)], startPoint: .top, endPoint: .bottom)
            PaperFibres()
            HStack {
                LinearGradient(colors: [PaperStyle.line.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 7)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, PaperStyle.line.opacity(0.08)], startPoint: .leading, endPoint: .trailing).frame(width: 5)
            }
        }
        .clipShape(ReceiptPaper())
        .overlay { ReceiptPaper().stroke(PaperStyle.line.opacity(0.32), lineWidth: 0.65) }
        .shadow(color: Color(red: 0.23, green: 0.18, blue: 0.27).opacity(0.15), radius: 3, y: 2)
    }
}

/// Preserve the paper's dimensions. Feed it down through a fixed top aperture;
/// never scale the text or use opacity to simulate printing.
private struct PaperFeedLayout: Layout {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let paper = subviews.first else { return .zero }
        let size = paper.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // Reserve the complete sheet even while it is still inside the slot.
        // A changing host height would move the printer with every frame.
        return size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let paper = subviews.first else { return }
        let size = paper.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        paper.place(at: CGPoint(x: bounds.minX, y: bounds.minY - size.height * (1 - progress)), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// A single interpolated timeline: tension, a fast diagonal rip, then gravity.
/// Recomputed on the rendering host, not eight independently reloaded poses.
nonisolated private struct ReceiptTearEffect: AnimatableModifier {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let pose = ReceiptTearPose(progress: progress)
        content
            .clipShape(TornTopEdge(rip: pose.rip))
            .overlay(alignment: .topTrailing) {
                LinearGradient(colors: [PaperStyle.line.opacity(0.55), Color(red: 0.99, green: 0.97, blue: 0.90), PaperStyle.paper], startPoint: .top, endPoint: .bottom)
                    .frame(height: 3 + pose.curl * 12)
                    .clipShape(TornTopEdge(rip: pose.rip))
                    .opacity(pose.curl).allowsHitTesting(false)
            }
            .rotation3DEffect(.degrees(pose.tilt), axis: (x: 1, y: -0.3, z: 0), anchor: .topLeading, perspective: 0.42)
            .rotationEffect(.degrees(pose.rotation), anchor: .topLeading)
            .offset(x: pose.x, y: pose.y)
            .shadow(color: .black.opacity(pose.shadow * 0.22), radius: pose.shadow * 12, x: 3 * pose.shadow, y: 8 * pose.shadow)
            .opacity(pose.opacity)
    }
}

private struct TornTopEdge: Shape {
    var rip: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let front = r.width * (1 - rip)
        p.move(to: .zero)
        // The tear advances from right to left across the fixed cutter.
        for index in 0...80 {
            let x = r.width * CGFloat(index) / 80
            let detached = min(1, max(0, (x - front) / 12))
            let tooth = index % 2 == 0 ? 3.0 : 0.0
            p.addLine(to: CGPoint(x: x, y: detached * (6 + tooth)))
        }
        p.addLine(to: CGPoint(x: r.width, y: r.height))
        p.addLine(to: CGPoint(x: 0, y: r.height)); p.closeSubpath()
        return p
    }
}

private struct ReceiptPaper: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let depth: CGFloat = 3.5
        let count = max(1, Int(r.width / 9))
        let step = r.width / CGFloat(count)
        p.move(to: CGPoint(x: 0, y: depth))
        for i in 0..<count {
            let x = CGFloat(i) * step
            p.addLine(to: CGPoint(x: x + step * 0.5, y: CGFloat(i % 3) * 0.3))
            p.addLine(to: CGPoint(x: x + step, y: depth))
        }
        p.addLine(to: CGPoint(x: r.width, y: r.height - depth))
        for i in (0..<count).reversed() {
            let x = CGFloat(i) * step
            p.addLine(to: CGPoint(x: x + step * 0.5, y: r.height - CGFloat((i + 1) % 3) * 0.3))
            p.addLine(to: CGPoint(x: x, y: r.height - depth))
        }
        p.closeSubpath()
        return p
    }
}

private struct PaperFibres: View {
    var body: some View {
        Canvas { context, size in
            // Deterministic grain: no noise flicker when the host refreshes.
            for i in 0..<2400 {
                let x = CGFloat((i * 433 + 19) % 4001) / 4001 * size.width
                let y = CGFloat((i * 701 + 73) % 4003) / 4003 * size.height
                let light = i % 4 == 0
                let rect = CGRect(x: x, y: y, width: i % 7 == 0 ? 2.1 : 0.45, height: 0.5)
                context.fill(Path(ellipseIn: rect), with: .color(light ? .white.opacity(0.24) : PaperStyle.line.opacity(0.12)))
            }
            // A faint compression crease, with a lit edge beside its shadow.
            let y = size.height * 0.61
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.65)), with: .color(PaperStyle.line.opacity(0.10)))
            context.fill(Path(CGRect(x: 0, y: y + 0.8, width: size.width, height: 0.7)), with: .color(.white.opacity(0.22)))
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
