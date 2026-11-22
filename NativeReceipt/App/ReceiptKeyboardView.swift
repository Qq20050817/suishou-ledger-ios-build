import AppIntents
import SwiftUI
import ReceiptCore

/// Every key is an intent on the retained snippet. No focus, system keyboard,
/// input dialog or navigation is required to compose and choose Chinese text.
struct ReceiptKeyboardView: View {
    let snapshot: ReceiptSnapshot
    let field: String
    private var s: ReceiptSnapshot { snapshot }

    var body: some View {
        VStack(spacing: 4) {
            Text(s.textInput.isEmpty ? "在下方输入文字" : s.textInput)
                .font(.system(size: 14)).foregroundStyle(s.textInput.isEmpty ? PaperStyle.secondary : PaperStyle.ink)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .accessibilityLabel(s.textInput.isEmpty ? "尚未输入文字" : s.textInput)
            HStack(spacing: 4) {
                Text(!s.message.isEmpty ? s.message : s.pinyinInput.isEmpty ? modeHint : s.pinyinInput)
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(PaperStyle.violet).frame(maxWidth: .infinity, alignment: .leading)
                Button(intent: ReceiptKeyboardIntent(s, "clearComposition")) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).frame(width: 26, height: 20)
                }.buttonStyle(.plain).disabled(s.pinyinInput.isEmpty).accessibilityLabel("清除未选拼音")
            }.frame(height: 20)
            candidateStrip
            VStack(spacing: 4) {
                keyRow(s.keyboardMode == .numbers ? "1234567890" : "qwertyuiop")
                keyRow(s.keyboardMode == .numbers ? "-/:;()¥&@\"" : "asdfghjkl").padding(.horizontal, 9)
                HStack(spacing: 3) {
                    if s.keyboardMode == .pinyin {
                        control("分词", "key", "'", height: 36).frame(width: 31)
                    } else if s.keyboardMode == .english {
                        control(s.uppercase ? "⇧" : "↑", "shift", height: 36).frame(width: 31).accessibilityLabel("切换大小写")
                    } else {
                        control("ABC", "mode", "english", height: 36).frame(width: 31)
                    }
                    keyRow(s.keyboardMode == .numbers ? "，。？！'._" : "zxcvbnm")
                    Button(intent: ReceiptKeyboardIntent(s, "backspace")) {
                        Image(systemName: "delete.left").font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(KeyboardKeyStyle(control: true)).frame(width: 31).accessibilityLabel("退格")
                }
            }
            HStack(spacing: 4) {
                control(s.keyboardMode == .pinyin ? "中 / 英" : "英 / 中", "mode", "toggle").frame(width: 51)
                control(s.keyboardMode == .numbers ? (s.keyboardAlphabet == .pinyin ? "拼音" : "ABC") : "123", "mode", "numbers").frame(width: 42)
                control(s.pinyinInput.isEmpty ? "空格" : "选首词", "space")
                control("清空", "clear").frame(width: 40)
            }
            HStack(spacing: 6) {
                Button("放弃修改", intent: ReceiptTextActionIntent(s.cardID, "cancel"))
                    .buttonStyle(KeyboardKeyStyle(control: true))
                Button(field == "order" ? "查找订单" : "应用修改", intent: ReceiptTextActionIntent(s.cardID, "done"))
                    .buttonStyle(KeyboardKeyStyle(prominent: true))
            }.font(.system(size: 12, weight: .semibold)).frame(height: 36)
        }
    }

    private var modeHint: String {
        if PinyinEngine.shared.entryCount == 0 { return "拼音词库未载入" }
        return s.keyboardMode == .pinyin ? "拼音输入 · ü 请按 v" : s.keyboardMode == .english ? "英文输入" : "数字与符号"
    }

    private var candidateStrip: some View {
        let all = s.pinyinCandidates
        let page = min(max(0, s.candidatePage), max(0, (all.count - 1) / 3))
        let visible = Array(all.dropFirst(page * 3).prefix(3))
        return HStack(spacing: 3) {
            control("‹", "page", "-1").frame(width: 24).disabled(page == 0).accessibilityLabel("上一组候选词")
            if visible.isEmpty {
                Text(s.pinyinInput.isEmpty ? "中文候选词" : "检查拼音，或继续输入")
                    .font(.system(size: 11)).foregroundStyle(PaperStyle.secondary).frame(maxWidth: .infinity)
            } else {
                ForEach(visible) { candidate in
                    Button(intent: ReceiptPinyinChoiceIntent(s, candidate)) {
                        Text(candidate.text).font(.system(size: 14, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity, minHeight: 32)
                    }.buttonStyle(KeyboardKeyStyle(control: true)).accessibilityLabel("输入\(candidate.text)")
                }
            }
            control("›", "page", "1").frame(width: 24).disabled((page + 1) * 3 >= all.count).accessibilityLabel("下一组候选词")
        }.frame(height: 32)
    }

    private func keyRow(_ letters: String) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(letters).map(String.init), id: \.self) { key in
                let value = s.keyboardMode == .english && s.uppercase ? key.uppercased() : key
                Button(intent: ReceiptKeyboardIntent(s, "key", value)) {
                    Text(value).font(.system(size: 16, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(KeyboardKeyStyle())
            }
        }
    }

    private func control(_ title: String, _ operation: String, _ value: String = "_", height: CGFloat = 32) -> some View {
        Button(intent: ReceiptKeyboardIntent(s, operation, value)) {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: height)
        }.buttonStyle(KeyboardKeyStyle(control: true))
    }
}

private struct KeyboardKeyStyle: ButtonStyle {
    var control = false
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? .white : control ? PaperStyle.violet : PaperStyle.ink)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(prominent ? PaperStyle.violet : control ? PaperStyle.chip.opacity(0.75) : Color(red: 0.99, green: 0.97, blue: 0.93), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(PaperStyle.line.opacity(0.17), lineWidth: 0.5) }
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
